import argparse
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("security_bottles", Path(__file__).parents[1] / "security_bottles.py")
s = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(s)

NAME = "php@8.4"
VERSION = "8.4.27"
COMMIT = "a" * 40
SOURCE = {
    "url": f"https://api.github.com/repos/{s.PRIVATE_REPO}/releases/assets/12345",
    "auth": "github",
    "public_url": f"https://www.php.net/distributions/php-{VERSION}.tar.xz",
    "sha256": "b" * 64,
}
RECIPE = '''class PhpAT84 < Formula
  desc "PHP"
  homepage "https://www.php.net/"
  url "https://www.php.net/distributions/php-8.4.26.tar.xz"
  mirror "https://fossies.org/php-8.4.26.tar.xz"
  sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  license "PHP-3.01"
  revision 1

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 arm64_sequoia: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  end

  depends_on "libzip"
  def install
    system "make", "install"
  end
end
'''


def release():
    return {"schema": 1, "sources": {VERSION: copy.deepcopy(SOURCE)}, "formulae": {NAME: VERSION},
            "runners": [{"runner": "macos-15", "tag": "arm64_sequoia"},
                        {"runner": "ubuntu-24.04", "tag": "x86_64_linux"}]}


def make_archive(path, recipe, extra=None):
    prefix = f"{NAME}/{VERSION}/"
    entries = {
        f".brew/{NAME}.rb": recipe.encode(),
        "sbom.spdx.json": json.dumps({"files": [{"fileName": "12345"}],
                                     "downloadLocation": SOURCE["url"],
                                     "name": f"{s.PRIVATE_TAP}/{NAME}"}).encode(),
        "bin/php": b"\x7fELF\0compiled PHP payload\xff",
        "include/php/" + "a" * 150 + ".h": b"/* preserved header */\n",
    }
    entries.update(extra or {})
    with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as tar:
        for name, contents in entries.items():
            info = tarfile.TarInfo(prefix + name)
            info.mode = 0o755 if name == "bin/php" else 0o644
            info.mtime = 1700000000
            info.size = len(contents)
            tar.addfile(info, io.BytesIO(contents))
        info = tarfile.TarInfo(prefix + "bin/php-cli")
        info.type = tarfile.SYMTYPE
        info.linkname = "php"
        tar.addfile(info)


class PromotionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tap = self.root / "public"
        (self.tap / "Formula").mkdir(parents=True)
        self.formula = self.tap / "Formula" / f"{NAME}.rb"
        self.formula.write_text(RECIPE)
        for command in (["init", "-q"], ["config", "user.name", "Test"],
                        ["config", "user.email", "test@example.invalid"], ["add", "."],
                        ["commit", "-qm", "Public base"]):
            subprocess.run(["git", "-C", str(self.tap), *command], check=True)
        self.original_commit = s.git(self.tap, "rev-parse", "HEAD")
        self.manifest = release()
        self.recipe = s.public_recipe(RECIPE, VERSION, SOURCE)
        self.private_recipe = s.private_recipe(self.recipe, SOURCE)
        self.artifacts = self.root / "artifacts"
        self.bundle = self.root / "bundle"
        self.output = self.root / "promoted"
        for runner in self.manifest["runners"]:
            tag = runner["tag"]
            stage = self.artifacts / tag
            stage.mkdir(parents=True)
            bottles = self.root / f"bottles-{tag}"
            bottles.mkdir()
            (stage / f"{NAME}.rb").write_text(self.recipe)
            s.write_json(stage / "build.json", {
                "schema": 1, "repository": s.PRIVATE_REPO, "run_id": "123", "commit": COMMIT,
                "tag": tag, "release": self.manifest, "recipes": {NAME: s.digest(self.recipe.encode())},
            })
            archive = bottles / f"{NAME}--{VERSION}.{tag}.bottle.tar.gz"
            make_archive(archive, self.private_recipe)
            s.write_json(bottles / f"{NAME}--{VERSION}.{tag}.bottle.json", {
                f"{s.PRIVATE_TAP}/{NAME}": {
                    "formula": {"name": NAME, "pkg_version": VERSION},
                    "bottle": {"root_url": f"https://github.com/{s.PRIVATE_REPO}/releases/download/security-build-123",
                               "rebuild": 0, "tags": {tag: {
                                   "local_filename": archive.name, "filename": archive.name.replace("--", "-"),
                                   "sha256": s.file_digest(archive), "tab": {"runtime_dependencies": []},
                               }}},
                },
            })
            with patch.dict(os.environ, {"PHP_SECURITY_SOURCE_TOKEN": "", "HOMEBREW_GITHUB_API_TOKEN": ""}):
                s.record(argparse.Namespace(output=stage, bottles=bottles))
        s.collect(argparse.Namespace(input=self.artifacts, output=self.bundle))
        self.args = argparse.Namespace(input=self.bundle, output=self.output, tap=self.tap,
                                       run_id="123", build_commit=COMMIT)

    def promote(self):
        with patch.object(s, "check_public_source") as source_check:
            s.promote(self.args)
            source_check.assert_called_once_with(VERSION, SOURCE)

    def assert_rejected(self, message):
        with self.assertRaisesRegex(ValueError, message):
            self.promote()
        self.assertFalse(self.output.exists())
        self.assertEqual(s.git(self.tap, "rev-parse", "HEAD"), self.original_commit)

    def test_complete_matrix_promotes_without_changing_payload(self):
        self.promote()
        result = s.read_json(self.output / "promotion.json")
        self.assertEqual(len(result["bottles"]), 2)
        self.assertEqual(self.formula.read_text(), self.recipe)
        self.assertNotEqual(result["public_recipe_commit"], self.original_commit)
        for item in result["bottles"]:
            path = next(self.output.glob(f"*.{item['tag']}.bottle.tar.gz"))
            old = self.bundle / path.name
            before, after = s.inventory(old), s.inventory(path)
            for key in before:
                if key not in item["changed_metadata_files"]:
                    self.assertEqual(before[key], after[key])
            with tarfile.open(path) as tar:
                recipe = tar.extractfile(f"{NAME}/{VERSION}/.brew/{NAME}.rb").read().decode()
                self.assertEqual(recipe, self.recipe)
                sbom = json.load(tar.extractfile(f"{NAME}/{VERSION}/sbom.spdx.json"))
                self.assertEqual(sbom["files"][0]["fileName"], f"php-{VERSION}.tar.xz")
                self.assertEqual(sbom["downloadLocation"], SOURCE["public_url"])
            document = s.read_json(next(self.output.glob(f"*.{item['tag']}.bottle.json")))
            entry = document[f"{s.PUBLIC_TAP}/{NAME}"]
            self.assertEqual(entry["formula"]["tap_git_revision"], result["public_recipe_commit"])
            self.assertEqual(entry["bottle"]["root_url"], s.ROOT_URL)
            self.assertEqual(entry["bottle"]["tags"][item["tag"]]["sha256"], s.file_digest(path))

    def test_corrupt_archive_rejected(self):
        path = next(self.bundle.glob("*.tar.gz"))
        path.write_bytes(path.read_bytes() + b"corrupt")
        self.assert_rejected("artifact checksum")

    def test_missing_platform_rejected(self):
        path = self.bundle / "security-build.json"
        data = s.read_json(path)
        data["bottles"].pop()
        s.write_json(path, data)
        self.assert_rejected("Incomplete or duplicate")

    def test_duplicate_platform_rejected(self):
        path = self.bundle / "security-build.json"
        data = s.read_json(path)
        data["bottles"][1] = data["bottles"][0]
        s.write_json(path, data)
        self.assert_rejected("Incomplete or duplicate")

    def test_changed_recipe_rejected(self):
        self.formula.write_text(RECIPE.replace('depends_on "libzip"', 'depends_on "libzip@2"'))
        self.assert_rejected("Public recipe changed")

    def test_changed_formula_source_allowed(self):
        self.formula.write_text(self.recipe)
        self.promote()

    def test_already_committed_public_source_allowed(self):
        self.formula.write_text(self.recipe)
        s.git(self.tap, "add", ".")
        s.git(self.tap, "commit", "-qm", "Public source updated")
        self.promote()

    def test_currently_published_platform_cannot_be_dropped(self):
        self.formula.write_text(RECIPE.replace("arm64_sequoia:", "arm64_tahoe:"))
        self.assert_rejected("omits a currently published platform")

    def test_existing_public_bottles_rejected(self):
        self.formula.write_text(RECIPE.replace("8.4.26", VERSION))
        self.assert_rejected("already has public bottles")

    def test_wrong_run_provenance_rejected(self):
        self.args.run_id = "456"
        self.assert_rejected("provenance")

    def test_wrong_json_checksum_rejected(self):
        path = next(self.bundle.glob("*.bottle.json"))
        path.write_text(path.read_text() + " ")
        self.assert_rejected("artifact checksum")

    def test_wrong_bottle_version_rejected(self):
        path = self.bundle / "security-build.json"
        data = s.read_json(path)
        item = data["bottles"][0]
        bottle_path = self.bundle / item["json"]
        document = s.read_json(bottle_path)
        document[f"{s.PRIVATE_TAP}/{NAME}"]["formula"]["pkg_version"] = "8.4.28"
        s.write_json(bottle_path, document)
        item["json_sha256"] = s.file_digest(bottle_path)
        s.write_json(path, data)
        self.assert_rejected("Bottle version mismatch")

    def test_platform_rebuild_numbers_must_match(self):
        path = self.bundle / "security-build.json"
        data = s.read_json(path)
        item = data["bottles"][0]
        bottle_path = self.bundle / item["json"]
        document = s.read_json(bottle_path)
        document[f"{s.PRIVATE_TAP}/{NAME}"]["bottle"]["rebuild"] = 1
        s.write_json(bottle_path, document)
        item["json_sha256"] = s.file_digest(bottle_path)
        s.write_json(path, data)
        self.assert_rejected("Inconsistent rebuild")

    def test_public_source_mismatch_does_not_modify_tap(self):
        with patch.object(s, "check_public_source", side_effect=ValueError("source mismatch")):
            with self.assertRaisesRegex(ValueError, "source mismatch"):
                s.promote(self.args)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.formula.read_text(), RECIPE)

    def test_private_string_in_compiled_payload_rejected(self):
        path = self.root / "leaky.tar.gz"
        make_archive(path, self.private_recipe, {"bin/php": SOURCE["url"].encode()})
        with self.assertRaisesRegex(ValueError, "Private data remains"):
            s.repack(path, self.root / "bad-output.tar.gz", NAME, VERSION, self.recipe,
                     [(SOURCE["url"], SOURCE["public_url"]), (s.PRIVATE_TAP, s.PUBLIC_TAP)], [SOURCE["url"]])

    def test_path_traversal_rejected(self):
        path = self.root / "traversal.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            entry = tarfile.TarInfo("../../outside")
            tar.addfile(entry, io.BytesIO())
        with self.assertRaisesRegex(ValueError, "Unsafe archive"):
            s.inventory(path)

    def test_source_checksum_is_checked_against_public_bytes(self):
        source = dict(SOURCE, sha256=s.digest(b"public source"))
        responses = [io.BytesIO(json.dumps({"ref": f"refs/tags/php-{VERSION}"}).encode()), io.BytesIO(b"public source")]
        with patch.object(s.urllib.request, "urlopen", side_effect=responses):
            s.check_public_source(VERSION, source)
        responses = [io.BytesIO(json.dumps({"ref": f"refs/tags/php-{VERSION}"}).encode()), io.BytesIO(b"changed source")]
        with patch.object(s.urllib.request, "urlopen", side_effect=responses):
            with self.assertRaisesRegex(ValueError, "differs"):
                s.check_public_source(VERSION, source)

    def test_dependency_drift_rejected(self):
        documents = [{"formula": {"bottle": {"tags": {"tag": {"tab": {"runtime_dependencies": [
            {"full_name": "libzip", "pkg_version": "1.11.4"},
        ]}}}}}}]
        response = {"formulae": [{"full_name": "libzip", "versions": {"stable": "1.12.0"}, "revision": 0}]}
        with patch.object(s.subprocess, "check_output", return_value=json.dumps(response)):
            with self.assertRaisesRegex(ValueError, "Runtime dependency changed"):
                s.check_dependencies(documents)

    def test_github_auth_cannot_target_external_host(self):
        data = release()
        data["sources"][VERSION]["url"] = "https://example.invalid/archive.tar.xz"
        path = self.root / "manifest.json"
        s.write_json(path, data)
        with self.assertRaisesRegex(ValueError, "authentication is restricted"):
            s.manifest(path)

    def test_prepare_embeds_environment_reference_not_secret(self):
        path = self.root / "manifest.json"
        s.write_json(path, self.manifest)
        env = {"GITHUB_REPOSITORY": s.PRIVATE_REPO, "GITHUB_RUN_ID": "123", "GITHUB_SHA": COMMIT,
               "HOMEBREW_GITHUB_API_TOKEN": "secret-not-in-recipe"}
        with patch.dict(os.environ, env):
            s.prepare(argparse.Namespace(manifest=path, tap=self.tap, output=self.root / "prepared",
                                         tag="arm64_sequoia"))
        self.assertIn('ENV.fetch("HOMEBREW_GITHUB_API_TOKEN")', self.formula.read_text())
        self.assertNotIn("secret-not-in-recipe", self.formula.read_text())
        self.assertEqual((self.root / "prepared" / f"{NAME}.rb").read_text(), self.recipe)


if __name__ == "__main__":
    unittest.main()
