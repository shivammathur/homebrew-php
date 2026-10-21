"""Publish independent prebuilt releases, then verify them without blocking other uploads."""

import argparse
import json
import os
from pathlib import Path
import random
import subprocess
import time
from types import SimpleNamespace

import security_bottles as s
import security_release_batch as batch
import verify_security_packages as packages


def selected(args):
    catalog = batch.load_catalog(args.catalog)
    rows = batch.select(catalog, "", args.runs)
    s.require(rows, "Empty publication selection")
    return catalog, rows


def plan(args):
    _, rows = selected(args)
    matrix = {"include": [{"run": r["run_id"], "formula": r["formula"]} for r in rows]}
    value = json.dumps(matrix, separators=(",", ":"))
    print(value)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("matrix=" + value + "\n")


def one(args):
    catalog, rows = selected(args)
    s.require(len(rows) == 1, "A worker must own exactly one release")
    repo, tap, root = batch.destination(args.tap, "public")
    s.require(repo == batch.PRODUCTION_REPO, "This publisher is restricted to production")
    s.PUBLIC_REPO, s.PUBLIC_TAP, s.ROOT_URL = repo, tap, root
    return catalog, rows[0], repo, tap, root


def push_history(tap, message):
    """Preserve embedded recipe commits and merge only disjoint concurrent writes."""
    for attempt in range(20):
        batch.command("git", "fetch", "--no-tags", "origin", "main", cwd=tap)
        batch.command("git", "merge", "--no-edit", "-m", message, "origin/main", cwd=tap)
        result = subprocess.run([
            "git", "-c", "credential.helper=!gh auth git-credential", "push", "origin",
            "HEAD:refs/heads/main"], cwd=tap, text=True, capture_output=True)
        if result.returncode == 0:
            return s.git(tap, "rev-parse", "HEAD")
        # Reconcile an uncertain response before retrying. Never force a shared branch.
        remote = s.git(tap, "ls-remote", "origin", "refs/heads/main").split()[0]
        if remote == s.git(tap, "rev-parse", "HEAD"):
            return remote
        if not any(word in result.stderr.lower() for word in ("fetch first", "non-fast-forward", "failed to push")):
            raise RuntimeError(result.stderr)
        time.sleep(min(0.25 * (attempt + 1), 3) + random.random())
    raise RuntimeError("Concurrent branch updates did not settle; recover the saved publication bundle")


def save_report(args, row, report, push=False):
    s.write_json(args.output / "validation.json", report)
    ledger = args.tap / ".github/security-promotions" / (row["run_id"] + ".json")
    ledger.parent.mkdir(parents=True, exist_ok=True)
    s.write_json(ledger, report)
    batch.command("git", "add", "--", "Formula/" + row["formula"] + ".rb",
                  str(ledger.relative_to(args.tap)), cwd=args.tap)
    message = f"{row['formula']}: {report['state']} [skip-build] [skip ci]"
    if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=args.tap).returncode:
        batch.command("git", "commit", "-m", message, cwd=args.tap)
    batch.command("git", "bundle", "create", args.output / "publication.bundle", "--all", cwd=args.tap)
    if push:
        commit = push_history(args.tap, message)
        report["last_pushed_commit"] = commit
        s.write_json(args.output / "validation.json", report)
        batch.command("git", "bundle", "create", args.output / "publication.bundle", "--all", cwd=args.tap)


def publish(args):
    catalog, row, repo, tap, root = one(args)
    s.require(not s.git(args.tap, "status", "--porcelain"), "Publication checkout must be clean")
    ledger = args.tap / ".github/security-promotions" / (row["run_id"] + ".json")
    s.require(not ledger.exists(), "Release already has a publication ledger; inspect it instead of reuploading")
    urls = s.read_json(args.public_sources)
    source = catalog["sources"][row["version"]]
    url = urls.get(row["version"])
    s.require(url, "The selected release needs its final public source URL")
    args.output.mkdir(parents=True, exist_ok=False)
    observed = batch.fetch(row, args.output / "input")
    override = args.output / "public-source.json"
    s.write_json(override, {row["version"]: url} if source.get("public_repository") else {})
    if not source.get("public_repository"):
        s.require(url == source["public_url"], "Official source URL cannot be overridden")
    promoted = args.output / "promoted"
    equivalence_path = batch.HERE / "security-publication/public-source-equivalence.json"
    equivalence = s.read_json(equivalence_path) if equivalence_path.exists() else {}
    selected_equivalence = {row["version"]: equivalence[row["version"]]} if row["version"] in equivalence else {}
    s.promote(SimpleNamespace(input=args.output / "input", output=promoted, tap=args.tap,
                             run_id=row["run_id"], build_commit=row["commit"],
                             public_sources=override, source_archive_equivalence=selected_equivalence,
                             defer_release_checks=True))
    batch.command("brew", "bottle", "--merge", "--write", "--no-commit", "--root-url=" + root,
                  *sorted(promoted.glob("*.bottle.json")), cwd=promoted)
    report = s.read_json(promoted / "promotion.json")
    for bottle in report["bottles"]:
        bottle["payload_inventory_sha256"] = s.digest(json.dumps(bottle.pop("payload_sha256"), sort_keys=True).encode())
    report.update(formula=row["formula"], version=row["version"], revision=row["revision"],
                  destination=repo, mode="public", catalog_sha256=s.file_digest(args.catalog),
                  runtime_tests={p["tag"]: p["runtime_test"] for p in row["platforms"]},
                  live_release=observed, state="prepared", verification="pending",
                  prepared_at=batch.now(), publication_workflow_run=os.environ.get("GITHUB_RUN_ID"))
    s.write_json(args.output / "validation.json", report)
    # One complete multi-platform tag per worker. Homebrew performs collision checks.
    batch.command("brew", "pr-upload", "--root-url=" + root, cwd=promoted)
    report.update(state="published", package_uploaded_at=batch.now(), verification="pending")
    save_report(args, row, report, push=True)
    report["formula_pushed_at"] = batch.now()
    s.write_json(args.output / "validation.json", report)
    print(f"Published {row['formula']} with five bottles; independent verification is pending.", flush=True)


def verify(args):
    _, row, repo, tap, _ = one(args)
    report = s.read_json(args.output / "validation.json")
    s.require(report["state"] == "published" and report.get("formula_pushed_at"),
              "Verification must follow package upload and formula publication")
    promoted = args.output / "promoted"
    documents = [s.read_json(p) for p in sorted(promoted.glob("*.bottle.json"))]
    results = {}
    errors = []
    checks = {
        "packages": lambda: packages.verify(repo, tap, report, documents),
        "source": lambda: s.check_public_source(row["version"], {
            **s.read_json(args.output / "input/security-build.json")["release"]["sources"][row["version"]],
            "public_url": report["sources"][row["version"]]["url"],
            "sha256": report["sources"][row["version"]]["sha256"]}),
        "dependencies": lambda: s.check_dependencies(documents,
            s.read_json(args.output / "input/security-build.json")["release"].get("tap_dependencies", {}),
            allow_newer_certificates=True),
        "style": lambda: batch.command("brew", "style", tap + "/" + row["formula"]),
        "audit": lambda: batch.command("brew", "audit", "--skip-style", tap + "/" + row["formula"]),
        "sbom": lambda: batch.command("brew", "ruby", "-e",
            'require "sbom"; require "json_schemer"; schema = JSONSchemer.schema(SBOM.schema); ARGV.each { |p| abort "Invalid SBOM: #{p}" unless schema.validate(JSON.parse(File.read(p))).to_a.empty? }',
            "--", *sorted(promoted.glob("*.spdx.json"))),
    }
    for name, check in checks.items():
        try:
            result = check()
            results[name] = {"status": "passed", "observed_at": batch.now(), "result": result}
        except Exception as error:
            results[name] = {"status": "failed", "observed_at": batch.now(), "error": str(error)}
            errors.append(name)
        report["verification_checks"] = results
        s.write_json(args.output / "validation.json", report)
    report.update(verification="failed" if errors else "passed", verified_at=batch.now())
    if results["packages"]["status"] == "passed":
        report["published_package"] = results["packages"]["result"]
    save_report(args, row, report, push=True)
    s.require(not errors, "Post-publication checks failed: " + ", ".join(errors))
    print(f"Verified {row['formula']} after publication.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "publish", "verify"))
    parser.add_argument("--runs", default="")
    parser.add_argument("--catalog", type=Path, default=batch.HERE / "security-publication/catalog.json")
    parser.add_argument("--public-sources", type=Path, default=batch.HERE / "security-publication/public-sources.json")
    parser.add_argument("--tap", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    args.tap = args.tap.resolve()
    if args.output:
        args.output = args.output.resolve()
    globals()[args.command](args)


if __name__ == "__main__":
    main()
