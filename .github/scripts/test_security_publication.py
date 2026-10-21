"""Run the production promotion path against one explicitly private test destination."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import urllib.request

import security_bottles as s

TEST_REPO = "shivammathur/homebrew-php-security-test"
TEST_TAP = "shivammathur/php-security-test"
TEST_ROOT = "https://ghcr.io/v2/shivammathur/php-security-test"


def verify_destination(tap):
    s.require(os.environ.get("GITHUB_REPOSITORY") == TEST_REPO,
              "This adapter can run only in the private test repository")
    s.require(s.git(tap, "remote", "get-url", "origin") in (
        f"https://github.com/{TEST_REPO}", f"https://github.com/{TEST_REPO}.git"),
        "The checked-out tap must be the test repository")
    repo = json.loads(subprocess.check_output(["gh", "api", f"repos/{TEST_REPO}"], text=True))
    s.require(repo["full_name"] == TEST_REPO and repo["private"] is True,
              "The test repository must remain private")


def verify_test_source(version, source, fixture):
    # The future public URL stays in the formula; this test does not waive the production announcement gate.
    s.validate_public_url(version, source)
    s.require(source.get("auth", "none") == "none" and source["url"] ==
              f"https://setup-php.com/php-oct-sr-builds/php-{version}.tar.xz",
              "Only the recorded pre-release test archive is allowed")
    s.require(fixture["repository"] == TEST_REPO and fixture["version"] == version
              and fixture["sha256"] == source["sha256"] and type(fixture["asset_id"]) is int,
              "Private test source fixture does not match the built source")
    endpoint = f"repos/{TEST_REPO}/releases/assets/{fixture['asset_id']}"
    contents = subprocess.check_output(["gh", "api", "--allow-escape-sequences", endpoint, "-H", "Accept: application/octet-stream"])
    s.require(s.digest(contents) == source["sha256"],
              "Test source archive differs from the privately built source")
    return {"version": version, "verified_url": "https://api.github.com/" + endpoint, "sha256": source["sha256"],
            "future_public_url": source["public_url"], "public_availability_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tap", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--build-commit", required=True)
    parser.add_argument("--source-fixture", type=Path, required=True)
    args = parser.parse_args()
    verify_destination(args.tap)
    s.PUBLIC_REPO, s.PUBLIC_TAP, s.ROOT_URL = TEST_REPO, TEST_TAP, TEST_ROOT
    source_results = []
    fixture = s.read_json(args.source_fixture)["source_fixture"]

    def source_check(version, source):
        source_results.append(verify_test_source(version, source, fixture))

    production_dependency_check = s.check_dependencies

    def dependency_check(documents, tap_dependencies=None):
        # Certificate trust data has no binary ABI; retain original recorded dependency versions.
        production_dependency_check(documents, tap_dependencies, allow_newer_certificates=True)

    s.check_public_source = source_check
    s.check_dependencies = dependency_check
    s.promote(args)
    s.write_json(args.output / "test-source-validation.json", {
        "verified_at": datetime.now(timezone.utc).isoformat(),
        "destination_repository": TEST_REPO, "destination_private": True,
        "sources": source_results, "newer_certificate_data_allowed": True,
        "compiled_dependency_versions": "exact match required",
        "production_announcement_gate": "unchanged; not exercised by this private test",
    })


if __name__ == "__main__":
    main()
