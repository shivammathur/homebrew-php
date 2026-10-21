import argparse
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from test_security_bottles import s


class BackportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.name, self.version, self.pkg = "php@8.1-zts", "8.1.34", "8.1.34_4"
        self.source = {"url": "https://setup-php.com/php-oct-sr-builds/php-8.1.34.tar.gz",
                       "public_repository": s.BACKPORTS_REPO, "public_url": None,
                       "auth": "none", "sha256": s.digest(b"identical source archive")}
        self.public_url = f"https://github.com/{s.BACKPORTS_REPO}/archive/" + "b" * 40 + ".tar.gz"
        self.old = ('class PhpAT81Zts < Formula\n  desc "PHP"\n  homepage "https://www.php.net/"\n'
                    f'  url "https://github.com/{s.BACKPORTS_REPO}/archive/' + "c" * 40 + '.tar.gz"\n'
                    '  version "8.1.34"\n  sha256 "' + "d" * 64 + '"\n  license "PHP-3.01"\n'
                    '  revision 3\n\n  depends_on "libzip"\nend\n')
        self.data = {"schema": 1, "sources": {self.version: self.source},
                     "formulae": {self.name: self.version}, "revisions": {self.name: 4},
                     "runners": [{"runner": ["self-hosted", "Linux", "X64", "ubuntu-24-sf"],
                                  "tag": "x86_64_linux"}]}
        self.manifest = self.root / "release.json"
        self.runtime_dependencies = []
        s.write_json(self.manifest, self.data)
        self.tap = self.root / "private"
        (self.tap / "Formula").mkdir(parents=True)
        self.formula = self.tap / "Formula" / (self.name + ".rb")
        self.formula.write_text(self.old.replace("revision 3", "revision 4"))
        self.stage, self.bottles = self.root / "stage", self.root / "bottles"
        self.bottles.mkdir()
        self.env = {"GITHUB_REPOSITORY": s.PRIVATE_REPO, "GITHUB_RUN_ID": "789",
                    "GITHUB_SHA": "a" * 40, "HOMEBREW_GITHUB_API_TOKEN": "", "PHP_SECURITY_SOURCE_TOKEN": ""}
        self.public = self.root / "public"
        (self.public / "Formula").mkdir(parents=True)
        (self.public / "Formula" / (self.name + ".rb")).write_text(self.old)
        for cmd in (["init", "-q"], ["config", "user.name", "Test"],
                    ["config", "user.email", "test@example.invalid"], ["add", "."], ["commit", "-qm", "Base"]):
            subprocess.run(["git", "-C", str(self.public), *cmd], check=True)

    def prepare(self):
        with patch.dict(os.environ, self.env):
            s.prepare(argparse.Namespace(manifest=self.manifest, formula=self.name, tap=self.tap,
                                         output=self.stage, tag="x86_64_linux"))

    def bundle(self):
        self.prepare()
        archive = self.bottles / f"{self.name}--{self.pkg}.x86_64_linux.bottle.tar.gz"
        payload = {f".brew/{self.name}.rb": self.formula.read_bytes(), "bin/php": b"compiled PHP, unchanged",
                   "sbom.spdx.json": json.dumps({"downloadLocation": self.source["url"],
                        "files": [{"fileName": "php-8.1.34.tar.gz"}]}).encode()}
        with tarfile.open(archive, "w:gz") as tar:
            for name, data in payload.items():
                entry = tarfile.TarInfo(f"{self.name}/{self.pkg}/{name}")
                entry.size, entry.mode, entry.mtime = len(data), 0o755, 1700000000
                tar.addfile(entry, io.BytesIO(data))
        s.write_json(archive.with_suffix("").with_suffix(".json"), {f"{s.PRIVATE_TAP}/{self.name}": {
            "formula": {"name": self.name, "pkg_version": self.pkg},
            "bottle": {"root_url": f"https://github.com/{s.PRIVATE_REPO}/releases/download/security-build-789",
                       "tags": {"x86_64_linux": {"local_filename": archive.name,
                           "sha256": s.file_digest(archive), "tab": {"runtime_dependencies": self.runtime_dependencies}}}}}})
        with patch.dict(os.environ, self.env):
            s.finalize(argparse.Namespace(output=self.stage, bottles=self.bottles, outcome="success"))
        inputs = self.root / "inputs"
        inputs.mkdir()
        self.stage.rename(inputs / "security-x86_64_linux")
        bundle = self.root / "bundle"
        s.collect(argparse.Namespace(input=inputs, output=bundle))
        urls = self.root / "public-urls.json"
        s.write_json(urls, {self.version: self.public_url})
        return argparse.Namespace(input=bundle, output=self.root / "promoted", tap=self.public,
                                  run_id="789", build_commit="a" * 40, public_sources=urls)

    def test_prepare_keeps_version_and_bumped_revision(self):
        self.prepare()
        self.assertEqual(s.package_version(s.manifest(self.manifest), self.name), self.pkg)
        self.assertIn('  revision 4\n', self.formula.read_text())
        self.assertEqual(self.formula.read_text().count('  version "8.1.34"'), 1)
        self.assertIn(self.source["url"], self.formula.read_text())
        data = json.loads(subprocess.check_output(["python3", str(Path(s.__file__)), "matrix",
                                                  "--manifest", str(self.manifest)]))
        self.assertIn("ubuntu-24-sf", data["include"][0]["runner"])
        self.assertEqual(data["include"][0]["container"]["image"], "ghcr.io/homebrew/brew:main")

    def test_prepare_rejects_unbumped_revision(self):
        self.formula.write_text(self.old)
        with self.assertRaisesRegex(ValueError, "run brew bump-revision"):
            self.prepare()

    def test_revision_stays_after_multiline_license(self):
        license_stanza = '  license all_of: [\n    "PHP-3.01",\n    "Zend-2.0",\n  ]\n'
        self.formula.write_text(self.formula.read_text().replace('  license "PHP-3.01"\n', license_stanza))
        self.prepare()
        self.assertIn(license_stanza + '  revision 4\n', self.formula.read_text())

    def test_prepare_preserves_real_embedded_patches(self):
        repo = Path(s.__file__).parents[2]
        release = s.read_json(repo / 'release-backports.json')
        for name, version in release['formulae'].items():
            original = (repo / 'Formula' / (name + '.rb')).read_text()
            if '\n__END__\n' not in original:
                continue
            with self.subTest(formula=name):
                prepared = s.public_recipe(original, version, release['sources'][version],
                                           release['revisions'][name])
                self.assertEqual(original.split('\n__END__\n', 1)[1],
                                 prepared.split('\n__END__\n', 1)[1])

    def test_patch_context_whitespace_is_part_of_recipe_fingerprint(self):
        recipe = self.old + '\n__END__\n@@ -1,3 +1,3 @@\n context\n\n\n'
        damaged = re.sub(r'\n{3,}', '\n\n', recipe)
        self.assertNotEqual(s.recipe_fingerprint(recipe), s.recipe_fingerprint(damaged))

    def test_missing_or_invalid_revision_rejected(self):
        for revisions in ({}, {self.name: 0}, {self.name: True}, {self.name: -1}):
            with self.subTest(revisions=revisions):
                s.write_json(self.manifest, dict(self.data, revisions=revisions))
                with self.assertRaisesRegex(ValueError, "revision"):
                    s.manifest(self.manifest)

    def test_future_url_promotion_preserves_compiled_payload_and_revision(self):
        args = self.bundle()
        with patch.object(s.urllib.request, "urlopen", return_value=io.BytesIO(b"identical source archive")) as fetch:
            s.promote(args)
            fetch.assert_called_once_with(self.public_url, timeout=120)
        result = s.read_json(args.output / "promotion.json")
        self.assertEqual(result["revisions"], {self.name: 4})
        promoted = (self.public / "Formula" / (self.name + ".rb")).read_text()
        self.assertIn(self.public_url, promoted)
        self.assertIn('  revision 4\n', promoted)
        self.assertNotIn(self.source["url"], promoted)
        original = next(args.input.glob("*.bottle.tar.gz"))
        output = args.output / original.name
        before, after = s.inventory(original), s.inventory(output)
        self.assertEqual(before.keys(), after.keys())
        for name in before:
            if name not in result["bottles"][0]["changed_metadata_files"]:
                self.assertEqual(before[name], after[name])
        with tarfile.open(output) as tar:
            embedded = tar.extractfile(f"{self.name}/{self.pkg}/.brew/{self.name}.rb").read().decode()
            self.assertEqual(embedded, promoted)
            sbom = json.load(tar.extractfile(f"{self.name}/{self.pkg}/sbom.spdx.json"))
            self.assertEqual(sbom["downloadLocation"], self.public_url)
            self.assertEqual(sbom["files"][0]["fileName"], "b" * 40 + ".tar.gz")

    def archive_equivalence(self):
        return {"schema": 1, "version": self.version, "php_version": self.version,
                "source_contents_identical": True, "tag_sha": "b" * 40, "commit": "a" * 40,
                "public_url": self.public_url, "private_archive_sha256": self.source["sha256"],
                "public_archive_sha256": s.digest(b"public wrapper, identical source tree"),
                "private_inventory_sha256": "e" * 64, "public_inventory_sha256": "e" * 64,
                "entries": 123, "private_root": "shivammathur-php-src-backports-security-" + "b" * 40,
                "public_root": "php-src-backports-" + "b" * 40}

    def test_public_archive_wrapper_mapping_preserves_build_provenance_and_payload(self):
        args = self.bundle()
        proof = self.archive_equivalence()
        args.source_archive_equivalence = {self.version: proof}
        with patch.object(s.urllib.request, "urlopen",
                          return_value=io.BytesIO(b"public wrapper, identical source tree")):
            s.promote(args)
        result = s.read_json(args.output / "promotion.json")
        self.assertEqual(result["source_archive_equivalence"][self.version], proof)
        self.assertEqual(result["sources"][self.version]["sha256"], proof["public_archive_sha256"])
        self.assertEqual(s.read_json(args.input / "security-build.json")["release"]["sources"][self.version]["sha256"],
                         proof["private_archive_sha256"])
        recipe = (self.public / "Formula" / (self.name + ".rb")).read_text()
        self.assertIn(proof["public_archive_sha256"], recipe)
        self.assertNotIn(proof["private_archive_sha256"], recipe)
        before = s.inventory(next(args.input.glob("*.bottle.tar.gz")))
        after = s.inventory(next(args.output.glob("*.bottle.tar.gz")))
        for name in before:
            if name not in result["bottles"][0]["changed_metadata_files"]:
                self.assertEqual(before[name], after[name])

    def test_source_archive_mapping_rejects_unbound_proofs(self):
        source = dict(self.source, public_url=self.public_url)
        changes = {"version": "7.0.33", "php_version": "7.0.33",
                   "source_contents_identical": False, "tag_sha": "c" * 40,
                   "private_archive_sha256": "f" * 64, "public_archive_sha256": "bad",
                   "public_inventory_sha256": "f" * 64, "entries": 0,
                   "public_root": "another-tree", "public_url": "https://example.invalid/archive.tar.gz"}
        for key, value in changes.items():
            with self.subTest(field=key):
                proof = dict(self.archive_equivalence(), **{key: value})
                with self.assertRaises(ValueError):
                    s.apply_source_archive_equivalence(self.version, dict(source), proof)

    def test_tagged_public_url_drops_only_redundant_version_metadata(self):
        self.public_url = f"https://github.com/{s.BACKPORTS_REPO}/archive/refs/tags/php-{self.version}-security-rehearsal.tar.gz"
        args = self.bundle()
        with patch.object(s.urllib.request, "urlopen", return_value=io.BytesIO(b"identical source archive")):
            s.promote(args)
        recipe = (self.public / "Formula" / (self.name + ".rb")).read_text()
        self.assertNotIn('  version "', recipe)
        self.assertIn('  revision 4\n', recipe)
        original = next(args.input.glob("*.bottle.tar.gz"))
        before, after = s.inventory(original), s.inventory(args.output / original.name)
        report = s.read_json(args.output / "promotion.json")["bottles"][0]
        for path in before:
            if path not in report["changed_metadata_files"]:
                self.assertEqual(before[path], after[path])
        with tarfile.open(args.output / original.name) as tar:
            self.assertEqual(tar.extractfile(f"{self.name}/{self.pkg}/.brew/{self.name}.rb").read().decode(), recipe)
        # A saved source-preparation commit must remain resumable without a second revision bump.
        args.output = self.root / "promoted-again"
        with patch.object(s.urllib.request, "urlopen", return_value=io.BytesIO(b"identical source archive")):
            s.promote(args)
        self.assertEqual((self.public / "Formula" / (self.name + ".rb")).read_text(), recipe)

    def test_public_version_detection_preserves_commit_urls_and_patch_data(self):
        data = "\n__END__\n@@ -1,3 +1,3 @@\n context\n\n\n"
        for url, explicit in [(self.public_url, True),
                             (f"https://github.com/{s.BACKPORTS_REPO}/releases/download/security/php-{self.version}.tar.gz", False)]:
            recipe = s.published_recipe(self.old + data, self.version, dict(self.source, public_url=url), 4)
            self.assertEqual('  version "8.1.34"' in recipe, explicit)
            self.assertTrue(recipe.endswith(data))

    def test_public_url_required_before_any_public_edit(self):
        args = self.bundle()
        args.public_sources = None
        with self.assertRaisesRegex(ValueError, "published backport URL"):
            s.promote(args)
        self.assertFalse(args.output.exists())
        self.assertEqual((self.public / "Formula" / (self.name + ".rb")).read_text(), self.old)

    def test_changed_source_checksum_blocks_publication(self):
        args = self.bundle()
        with patch.object(s.urllib.request, "urlopen", return_value=io.BytesIO(b"different archive")):
            with self.assertRaisesRegex(ValueError, "differs from the privately built"):
                s.promote(args)
        self.assertFalse(args.output.exists())
        self.assertEqual((self.public / "Formula" / (self.name + ".rb")).read_text(), self.old)

    def test_already_published_revision_is_not_overwritten(self):
        args = self.bundle()
        (self.public / "Formula" / (self.name + ".rb")).write_text(self.old.replace("revision 3", "revision 4"))
        with self.assertRaisesRegex(ValueError, "exactly one revision bump"):
            s.promote(args)

    def test_retry_after_source_commit_does_not_bump_again(self):
        args = self.bundle()
        resolved = dict(self.source, public_url=self.public_url)
        (self.public / "Formula" / (self.name + ".rb")).write_text(
            s.public_recipe(self.old, self.version, resolved, 4))
        with patch.object(s.urllib.request, "urlopen", return_value=io.BytesIO(b"identical source archive")):
            s.promote(args)
        self.assertEqual(s.read_json(args.output / "promotion.json")["revisions"], {self.name: 4})

    def test_unrelated_public_repository_is_rejected(self):
        args = self.bundle()
        s.write_json(args.public_sources, {self.version: "https://example.invalid/php-8.1.34.tar.gz"})
        with self.assertRaisesRegex(ValueError, "must belong to php-src-backports"):
            s.promote(args)
        self.assertFalse(args.output.exists())

    def add_tap_dependencies(self):
        self.old = self.old.replace('  depends_on "libzip"',
            '  depends_on "shivammathur/php/bison@2.7" => :build\n'
            '  depends_on "shivammathur/php/autoconf@2.69"\n  depends_on "libzip"')
        self.formula.write_text(self.old.replace("revision 3", "revision 4"))
        (self.public / "Formula" / (self.name + ".rb")).write_text(self.old)
        self.data["tap_dependencies"] = {}
        for name in sorted(s.TAP_DEPENDENCIES):
            recipe = '# Public helper recipe: ' + name + '\n'
            for tap in (self.tap, self.public):
                (tap / "Formula" / (name + ".rb")).write_text(recipe)
            self.data["tap_dependencies"][name] = s.digest(recipe.encode())
        s.write_json(self.manifest, self.data)
        self.runtime_dependencies = [{"full_name": s.PRIVATE_TAP + "/autoconf@2.69", "pkg_version": "2.69"}]

    def test_tap_dependency_identity_is_restored_at_promotion(self):
        self.add_tap_dependencies()
        args = self.bundle()
        self.assertIn('depends_on "shivammathur/php-security/bison@2.7"', self.formula.read_text())
        self.assertIn('depends_on "shivammathur/php-security/autoconf@2.69"', self.formula.read_text())
        original_check_output = subprocess.check_output
        def check_output(command, **kwargs):
            if command[:2] == ['brew', 'info']:
                self.assertEqual(command[-1], 'shivammathur/php/autoconf@2.69')
                return json.dumps({'formulae': [{'full_name': command[-1], 'versions': {'stable': '2.69'}, 'revision': 0}]})
            return original_check_output(command, **kwargs)
        with patch.object(s.urllib.request, "urlopen", return_value=io.BytesIO(b"identical source archive")), \
                patch.object(s.subprocess, 'check_output', side_effect=check_output):
            s.promote(args)
        document = s.read_json(next(args.output.glob('*.bottle.json')))
        dep = document[s.PUBLIC_TAP + '/' + self.name]['bottle']['tags']['x86_64_linux']['tab']['runtime_dependencies'][0]
        self.assertEqual(dep['full_name'], s.PUBLIC_TAP + '/autoconf@2.69')

    def test_tap_dependency_recipe_must_match_before_build(self):
        self.add_tap_dependencies()
        (self.tap / 'Formula' / 'autoconf@2.69.rb').write_text('# changed\n')
        with self.assertRaisesRegex(ValueError, 'Private dependency recipe differs'):
            self.prepare()

    def test_tap_dependency_recipe_must_match_before_promotion(self):
        self.add_tap_dependencies()
        args = self.bundle()
        (self.public / 'Formula' / 'autoconf@2.69.rb').write_text('# changed\n')
        with self.assertRaisesRegex(ValueError, 'Public dependency recipe changed'):
            s.promote(args)
        self.assertFalse(args.output.exists())

    def stash_fixture(self, suffix):
        self.prepare()
        archive = self.bottles / f'{self.name}--{self.pkg}.x86_64_linux.bottle{suffix}.tar.gz'
        archive.write_bytes(b'complete bottle bytes')
        metadata = self.bottles / f'{self.name}--{self.pkg}.x86_64_linux.bottle.json'
        s.write_json(metadata, {s.PRIVATE_TAP + '/' + self.name: {
            'formula': {'name': self.name, 'pkg_version': self.pkg},
            'bottle': {'tags': {'x86_64_linux': {'local_filename': archive.name,
                                               'sha256': s.file_digest(archive)}}}}})
        return archive, metadata, argparse.Namespace(output=self.stage, bottles=self.bottles, formula=self.name)

    def test_stash_preserves_bottle_rebuild_suffix(self):
        archive, metadata, args = self.stash_fixture('.1')
        s.stash(args)
        self.assertEqual({p.name for p in (self.stage / 'bottles').iterdir()}, {archive.name, metadata.name})
        self.assertEqual((self.stage / 'bottles' / archive.name).read_bytes(), b'complete bottle bytes')
        self.assertFalse(archive.exists())

    def test_stash_preserves_plain_bottle_filename(self):
        archive, metadata, args = self.stash_fixture('')
        s.stash(args)
        self.assertTrue((self.stage / 'bottles' / archive.name).exists())

    def test_stash_rejects_corrupt_bottle_before_moving_files(self):
        archive, metadata, args = self.stash_fixture('.1')
        archive.write_bytes(b'incomplete')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            s.stash(args)
        self.assertTrue(archive.exists())
        self.assertTrue(metadata.exists())
        self.assertFalse((self.stage / 'bottles').exists())


class UnusedPatchRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.name = 'php@5.6-debug'
        repo = Path(s.__file__).parents[2]
        self.release = s.manifest(repo / 'release-backports.json', self.name)
        self.corrected = s.public_recipe((repo / 'Formula' / (self.name + '.rb')).read_text(),
            '5.6.40', self.release['sources']['5.6.40'], self.release['revisions'][self.name])
        self.damaged = re.sub(r'\n{3,}', '\n\n', self.corrected)
        self.release['runners'] = [{'tag': 'arm64_sequoia', 'runner': 'macos-15-arm64'},
                                   {'tag': 'x86_64_linux', 'runner': 'ubuntu-24-sf'}]
        self.inputs = self.root / 'inputs'
        self.env = {'GITHUB_REPOSITORY': s.PRIVATE_REPO, 'GITHUB_RUN_ID': '456', 'GITHUB_SHA': 'd' * 40}
        for tag, recipe, run, commit in [('arm64_sequoia', self.corrected, '456', 'd' * 40),
                                         ('x86_64_linux', self.damaged, '123', 'a' * 40)]:
            stage = self.inputs / tag
            stage.mkdir(parents=True)
            (stage / (self.name + '.rb')).write_text(recipe)
            files = {'archive': tag + '.tar.gz', 'json': tag + '.json'}
            for key, filename in files.items():
                (stage / filename).write_bytes((key + ':' + tag).encode())
            entry = dict(files, formula=self.name, sha256=s.file_digest(stage / files['archive']),
                         json_sha256=s.file_digest(stage / files['json']))
            release = dict(self.release)
            if tag.endswith('_linux'):
                release.pop('tap_dependencies', None)
            s.write_json(stage / 'build.json', {'schema': 1, 'repository': s.PRIVATE_REPO,
                'run_id': run, 'commit': commit, 'release': release, 'tag': tag,
                'recipes': {self.name: s.digest(recipe.encode())}, 'bottles': [entry]})
        self.args = argparse.Namespace(input=self.inputs, output=self.root / 'bundle',
                                       reuse_run='123', reuse_commit='a' * 40)

    def test_collect_preserves_unused_linux_patch_provenance_and_payload(self):
        with patch.dict(os.environ, self.env):
            s.collect(self.args)
        bundle = s.read_json(self.args.output / 'security-build.json')
        self.assertEqual((self.args.output / (self.name + '.rb')).read_text(), self.corrected)
        linux = next(entry for entry in bundle['bottles'] if entry['tag'] == 'x86_64_linux')
        self.assertEqual(linux['build_recipe_sha256'], s.digest(self.damaged.encode()))
        self.assertEqual(linux['build_provenance']['commit'], 'a' * 40)
        self.assertEqual(linux['recipe_normalization'], 'preserve-unused-macos-patch-data')
        self.assertEqual((self.args.output / linux['archive']).read_bytes(), b'archive:x86_64_linux')

    def test_repair_rejects_macos_or_ruby_or_patch_content_changes(self):
        self.assertTrue(s.accepts_unused_macos_patch_repair(self.name, 'x86_64_linux', self.damaged, self.corrected))
        for name, tag, old in [(self.name, 'arm64_sequoia', self.damaged),
                               ('php@7.0', 'x86_64_linux', self.damaged),
                               (self.name, 'x86_64_linux', self.damaged.replace('  def install', '  def changed')),
                               (self.name, 'x86_64_linux', self.damaged.replace('diff --git', 'changed --git', 1))]:
            with self.subTest(name=name, tag=tag):
                self.assertFalse(s.accepts_unused_macos_patch_repair(name, tag, old, self.corrected))

    def test_collect_rejects_changed_archive_identity(self):
        path = self.inputs / 'x86_64_linux' / 'build.json'
        data = s.read_json(path)
        data['release']['sources']['5.6.40']['sha256'] = '0' * 64
        s.write_json(path, data)
        with patch.dict(os.environ, self.env):
            with self.assertRaisesRegex(ValueError, 'inconsistent release manifests'):
                s.collect(self.args)

    def test_recovery_manifest_does_not_depend_on_platform_directory_order(self):
        old = self.inputs / 'x86_64_linux'
        old.rename(self.inputs / '0-original-linux')
        with patch.dict(os.environ, self.env):
            s.collect(self.args)
        bundle = s.read_json(self.args.output / 'security-build.json')
        self.assertEqual(bundle['release'], self.release)
        self.assertEqual((self.args.output / (self.name + '.rb')).read_text(), self.corrected)
        self.assertEqual({entry['build_provenance']['run_id'] for entry in bundle['bottles']}, {'123', '456'})

    def flatten_artifact(self, tag):
        folder = self.inputs / tag
        for path in folder.iterdir():
            path.rename(self.inputs / path.name)
        folder.rmdir()

    def test_single_replacement_download_at_input_root(self):
        self.flatten_artifact('arm64_sequoia')
        with patch.dict(os.environ, self.env):
            s.collect(self.args)
        bundle = s.read_json(self.args.output / 'security-build.json')
        self.assertEqual(len(bundle['bottles']), 2)
        self.assertEqual(bundle['release'], self.release)

    def test_single_original_download_at_input_root(self):
        self.flatten_artifact('x86_64_linux')
        with patch.dict(os.environ, self.env):
            s.collect(self.args)
        bundle = s.read_json(self.args.output / 'security-build.json')
        self.assertEqual(len(bundle['bottles']), 2)
        self.assertEqual(bundle['release'], self.release)

    def test_duplicate_root_and_nested_platform_still_rejected(self):
        data = s.read_json(self.inputs / 'arm64_sequoia' / 'build.json')
        s.write_json(self.inputs / 'build.json', data)
        with patch.dict(os.environ, self.env):
            with self.assertRaisesRegex(ValueError, 'missing a platform or contains duplicates'):
                s.collect(self.args)

    def test_recovery_requires_an_artifact_from_the_exact_current_commit(self):
        with patch.dict(os.environ, dict(self.env, GITHUB_SHA='e' * 40)):
            with self.assertRaisesRegex(ValueError, 'missing artifacts from its own run and commit'):
                s.collect(self.args)

    def test_recovery_rejects_conflicting_helper_dependency_hashes(self):
        path = self.inputs / 'x86_64_linux' / 'build.json'
        data = s.read_json(path)
        data['release']['tap_dependencies'] = {'bison@2.7': 'e' * 64}
        s.write_json(path, data)
        with patch.dict(os.environ, self.env):
            with self.assertRaisesRegex(ValueError, 'inconsistent release manifests'):
                s.collect(self.args)
