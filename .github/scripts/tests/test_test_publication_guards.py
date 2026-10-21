import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import security_bottles as s
import test_security_publication as adapter


class TestDestinationGuards(unittest.TestCase):
    def test_production_repository_rejected(self):
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "shivammathur/homebrew-php"}):
            with self.assertRaisesRegex(ValueError, "only in the private test"):
                adapter.verify_destination(Path("."))

    def test_public_destination_rejected(self):
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": adapter.TEST_REPO}), \
             patch.object(s, "git", return_value=f"https://github.com/{adapter.TEST_REPO}.git"), \
             patch.object(adapter.subprocess, "check_output", return_value=json.dumps({
                 "full_name": adapter.TEST_REPO, "private": False})):
            with self.assertRaisesRegex(ValueError, "must remain private"):
                adapter.verify_destination(Path("."))

    def test_private_prefix_allowed_only_for_distinct_identity(self):
        for private, destination in [(s.PRIVATE_REPO, adapter.TEST_REPO), (s.PRIVATE_TAP, adapter.TEST_TAP)]:
            self.assertFalse(s.contains_private((destination + "/x").encode(), [private]))
            for suffix in ("", "/x", '"', ".git"):
                self.assertTrue(s.contains_private((private + suffix).encode(), [private]))
            self.assertFalse(s.contains_private(private.encode(), [private], final=False))
            self.assertTrue(s.contains_private((private + "/").encode(), [private], final=False))

    def test_changed_test_source_rejected(self):
        source = {"url": "https://setup-php.com/php-oct-sr-builds/php-8.2.35.tar.xz",
                  "public_url": "https://www.php.net/distributions/php-8.2.35.tar.xz",
                  "sha256": "0" * 64}
        fixture = {"repository": adapter.TEST_REPO, "version": "8.2.35",
                   "asset_id": 123, "sha256": "0" * 64}
        with patch.object(adapter.subprocess, "check_output", return_value=b"changed"):
            with self.assertRaisesRegex(ValueError, "differs"):
                adapter.verify_test_source("8.2.35", source, fixture)

    def test_newer_certificate_data_only(self):
        def check(name, built, current, allow=True):
            docs = [{"test": {"bottle": {"tags": {"arm64_golden_gate": {"tab": {
                "runtime_dependencies": [{"full_name": name, "pkg_version": built}]}}}}}}]
            result = {"formulae": [{"full_name": name, "versions": {"stable": current}, "revision": 0}]}
            with patch.object(s.subprocess, "check_output", return_value=json.dumps(result)):
                s.check_dependencies(docs, allow_newer_certificates=allow)
        check("ca-certificates", "2026-09-25", "2026-10-20")
        for params in [("ca-certificates", "2026-09-25", "2026-10-20", False),
                       ("ca-certificates", "2026-10-20", "2026-09-25", True),
                       ("libzip", "1.12.1", "1.12.2", True)]:
            with self.assertRaisesRegex(ValueError, "Runtime dependency changed"):
                check(*params)
