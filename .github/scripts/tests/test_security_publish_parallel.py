import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import security_publish_parallel as publisher


class ParallelPublicationTests(unittest.TestCase):
    def git(self, directory, *args):
        return subprocess.check_output(["git", "-C", str(directory), *args], text=True,
                                       stderr=subprocess.DEVNULL).strip()

    def test_disjoint_publishers_preserve_both_recipe_commits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            remote = root / "remote.git"
            subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(remote)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            first = root / "first"
            self.git(root, "clone", str(remote), str(first))
            self.git(first, "config", "user.name", "Publication Test")
            self.git(first, "config", "user.email", "publication@example.invalid")
            (first / "baseline").write_text("baseline\n")
            self.git(first, "add", ".")
            self.git(first, "commit", "-m", "baseline")
            self.git(first, "push", "origin", "main")
            second = root / "second"
            self.git(root, "clone", str(remote), str(second))
            self.git(second, "config", "user.name", "Publication Test")
            self.git(second, "config", "user.email", "publication@example.invalid")
            recipes = []
            for checkout, name in [(first, "one"), (second, "two")]:
                (checkout / name).write_text("prepared recipe\n")
                self.git(checkout, "add", name)
                self.git(checkout, "commit", "-m", "source recipe")
                recipes.append(self.git(checkout, "rev-parse", "HEAD"))
                (checkout / name).write_text("published bottle\n")
                self.git(checkout, "add", name)
                self.git(checkout, "commit", "-m", "bottle")
            publisher.push_history(first, "publish one [skip ci]")
            publisher.push_history(second, "publish two [skip ci]")
            self.assertEqual(self.git(remote, "show", "main:one"), "published bottle")
            self.assertEqual(self.git(remote, "show", "main:two"), "published bottle")
            for commit in recipes:
                self.git(remote, "merge-base", "--is-ancestor", commit, "main")

    def test_reports_remain_outside_the_published_tap(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tap = root / "tap"
            output = root / "output"
            tap.mkdir()
            output.mkdir()
            self.git(tap, "init", "--initial-branch=main")
            self.git(tap, "config", "user.name", "Publication Test")
            self.git(tap, "config", "user.email", "publication@example.invalid")
            (tap / "Formula").mkdir()
            formula = tap / "Formula/php@5.6.rb"
            formula.write_text("baseline\n")
            self.git(tap, "add", ".")
            self.git(tap, "commit", "-m", "baseline")
            formula.write_text("published bottle\n")
            args = SimpleNamespace(tap=tap, output=output)
            row = {"run_id": "123", "formula": "php@5.6"}
            publisher.save_report(args, row, {"state": "published"})
            self.assertEqual(self.git(tap, "show", "--format=", "--name-only", "HEAD"), "Formula/php@5.6.rb")
            self.assertFalse((tap / ".github/security-promotions").exists())
            self.assertEqual(json.loads((output / "validation.json").read_text())["state"], "published")
            self.assertTrue((output / "publication.bundle").is_file())

    def test_verify_requires_formula_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "validation.json").write_text(json.dumps({"state": "prepared"}))
            args = SimpleNamespace(output=output)
            with patch.object(publisher, "one", return_value=({}, {}, "repo", "tap", "root")):
                with self.assertRaisesRegex(ValueError, "must follow"):
                    publisher.verify(args)

    def test_worker_rejects_multiple_releases(self):
        args = SimpleNamespace()
        with patch.object(publisher, "selected", return_value=({}, [{}, {}])):
            with self.assertRaisesRegex(ValueError, "exactly one"):
                publisher.one(args)


if __name__ == "__main__":
    unittest.main()
