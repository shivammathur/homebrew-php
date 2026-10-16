"""Build privately, verify announced sources, and promote bottles without recompiling."""

import argparse
import copy
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import urllib.parse
import urllib.request


PRIVATE_REPO = "shivammathur/homebrew-php-security"
PUBLIC_REPO = "shivammathur/homebrew-php"
PRIVATE_TAP = "shivammathur/php-security"
PUBLIC_TAP = "shivammathur/php"
ROOT_URL = "https://ghcr.io/v2/shivammathur/php"
VERSION = re.compile(r"\d+\.\d+\.\d+\Z")
FORMULA = re.compile(r"php(?:@\d+\.\d+)?(?:-debug)?(?:-zts)?\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    with open(path, "rb") as stream:
        return stream_digest(stream)


def stream_digest(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        result.update(chunk)
    return result.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def git(tap, *args):
    return subprocess.check_output(["git", "-C", str(tap), *args], text=True).strip()


def basename(value):
    require(isinstance(value, str) and value == Path(value).name and value not in ("", ".", ".."),
            "Invalid artifact filename")
    return value


def manifest(path):
    data = read_json(path)
    require(data.get("schema") == 1, "Unsupported manifest schema")
    require(data.get("formulae") and data.get("runners"), "Formulae and runners are required")
    for version, source in data["sources"].items():
        require(VERSION.fullmatch(version), "Only final PHP releases can be staged")
        require(SHA256.fullmatch(source["sha256"]) and source["sha256"] != "0" * 64,
                "A real source SHA-256 is required")
        url = urllib.parse.urlsplit(source["url"])
        require(url.scheme == "https" and url.hostname and not url.username and not url.password and
                not url.fragment and not any(char.isspace() for char in source["url"]),
                "Private source URLs must use HTTPS without embedded credentials")
        require(source.get("auth", "none") in ("none", "github", "bearer"), "Unknown source authentication")
        if source.get("auth") == "github":
            require(url.hostname == "api.github.com" and re.fullmatch(
                rf"/repos/{PRIVATE_REPO}/releases/assets/\d+", url.path) and not url.query,
                "GitHub source authentication is restricted to this private repository's release assets")
        require(source["public_url"] in [f"https://www.php.net/distributions/php-{version}.tar.{ext}"
                                         for ext in ("xz", "gz", "bz2")],
                "Public sources must be official php.net release archives")
    for name, version in data["formulae"].items():
        require(FORMULA.fullmatch(name) and version in data["sources"], "Invalid formula/version mapping")
        series = re.search(r"@(\d+\.\d+)", name)
        require(not series or version.startswith(series[1] + "."), "Formula series does not match source")
    require(set(data["sources"]) == set(data["formulae"].values()), "Unused or missing source in release manifest")
    tags = [item["tag"] for item in data["runners"]]
    require(len(tags) == len(set(tags)), "Duplicate platform in runner matrix")
    for item in data["runners"]:
        require(re.fullmatch(r"[a-z0-9_]+", item["tag"]), "Invalid bottle tag")
        labels = item["runner"] if isinstance(item["runner"], list) else [item["runner"]]
        require(labels and all(isinstance(label, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", label)
                               for label in labels), "Invalid runner labels")
    return data


def without_bottles(recipe):
    return re.sub(r"\n  bottle do\n.*?\n  end\n", "\n", recipe, flags=re.S)


def recipe_fingerprint(recipe):
    recipe = without_bottles(recipe)
    recipe = re.sub(r"^  (?:url|mirror|version|sha256|revision) .*\n", "", recipe, flags=re.M)
    return digest(re.sub(r"\n{3,}", "\n\n", recipe).strip().encode())


def public_recipe(recipe, version, source):
    recipe = without_bottles(recipe)
    require(len(re.findall(r'^  url "[^"\n]+"\n', recipe, re.M)) == 1,
            "Expected one simple top-level release URL; prepare the recipe before building")
    recipe = re.sub(r"^  (?:mirror|version|revision) .*\n", "", recipe, flags=re.M)
    recipe = re.sub(r'^  url "[^"\n]+"\n', f'  url "{source["public_url"]}"\n', recipe, flags=re.M)
    recipe, count = re.subn(r'^  sha256 "[0-9a-f]+"\n', f'  sha256 "{source["sha256"]}"\n',
                           recipe, flags=re.M)
    require(count == 1, "Expected one source checksum")
    require(version in source["public_url"], "Source URL/version mismatch")
    return re.sub(r"\n{3,}", "\n\n", recipe)


def private_recipe(recipe, source):
    # Credentials stay in the environment, including when Homebrew embeds this recipe in a bottle.
    auth = source.get("auth", "none")
    replacement = f'  url {json.dumps(source["url"])}\n'
    if auth != "none":
        variable = "HOMEBREW_GITHUB_API_TOKEN" if auth == "github" else "PHP_SECURITY_SOURCE_TOKEN"
        replacement = (f'  url {json.dumps(source["url"])},\n'
                       '      headers: ["Accept: application/octet-stream",\n'
                       f'                "Authorization: Bearer #{{ENV.fetch("{variable}")}}"]\n')
    recipe = recipe.replace(f'  url "{source["public_url"]}"\n', replacement)
    version = re.search(r"php-(\d+\.\d+\.\d+)\.tar", source["public_url"])[1]
    return recipe.replace(f'  sha256 "{source["sha256"]}"',
                          f'  version "{version}"\n  sha256 "{source["sha256"]}"', 1)


def prepare(args):
    data = manifest(args.manifest)
    require(args.tag in {item["tag"] for item in data["runners"]}, "Unexpected build platform")
    require(os.environ.get("GITHUB_REPOSITORY") == PRIVATE_REPO, "Builds must run in the private repository")
    args.output.mkdir(parents=True, exist_ok=False)
    recipes = {}
    for name, version in data["formulae"].items():
        if data["sources"][version].get("auth") == "bearer":
            require(os.environ.get("PHP_SECURITY_SOURCE_TOKEN"), "PHP_SECURITY_SOURCE_TOKEN is required")
        path = args.tap / "Formula" / f"{name}.rb"
        recipe = public_recipe(path.read_text(), version, data["sources"][version])
        recipes[name] = recipe
        (args.output / f"{name}.rb").write_text(recipe)
        path.write_text(private_recipe(recipe, data["sources"][version]))
    write_json(args.output / "build.json", {
        "schema": 1, "repository": PRIVATE_REPO,
        "run_id": os.environ["GITHUB_RUN_ID"], "commit": os.environ["GITHUB_SHA"],
        "tag": args.tag, "release": data,
        "recipes": {name: digest(recipe.encode()) for name, recipe in recipes.items()},
    })


def rewrite(value, substitutions):
    if isinstance(value, str):
        for old, new in substitutions:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [rewrite(item, substitutions) for item in value]
    if isinstance(value, dict):
        return {rewrite(key, substitutions): rewrite(item, substitutions) for key, item in value.items()}
    return value


def inventory(path):
    result = {}
    with tarfile.open(path) as archive:
        for member in archive:
            require(member.name not in result, "Duplicate archive member")
            require(not member.name.startswith("/") and ".." not in PurePosixPath(member.name).parts,
                    "Unsafe archive member")
            require(member.isfile() or member.isdir() or member.issym() or member.islnk(),
                    "Unsupported archive member")
            result[member.name] = {"type": member.type.decode(), "mode": member.mode,
                                   "uid": member.uid, "gid": member.gid, "mtime": member.mtime,
                                   "link": member.linkname, "pax": member.pax_headers,
                                   "sha256": stream_digest(archive.extractfile(member))
                                   if member.isfile() else None}
    return result


def scan_archive(path, forbidden):
    # Bounded chunks also detect strings crossing a chunk boundary in large PHP binaries.
    needles = [value.encode() for value in forbidden if value]
    overlap = max(map(len, needles), default=1) - 1
    with tarfile.open(path) as archive:
        for member in archive:
            require(not any(value in member.name.encode() for value in needles), "Private archive member name")
            require(not any(value in member.linkname.encode() for value in needles), "Private archive link")
            require(not any(value in json.dumps(member.pax_headers).encode() for value in needles),
                    "Private archive metadata")
            if not member.isfile():
                continue
            stream = archive.extractfile(member)
            tail = b""
            while chunk := stream.read(1024 * 1024):
                block = tail + chunk
                require(not any(value in block for value in needles), "Private data remains in bottle payload")
                tail = block[-overlap:] if overlap else b""


def record(args):
    build = read_json(args.output / "build.json")
    expected = set(build["release"]["formulae"])
    found = set()
    build["bottles"] = []
    for path in args.bottles.glob("*.bottle.json"):
        document = read_json(path)
        require(len(document) == 1, "Expected one formula per bottle JSON")
        full_name, entry = next(iter(document.items()))
        name = entry["formula"]["name"]
        require(name in expected and name not in found and full_name == f"{PRIVATE_TAP}/{name}",
                "Unexpected or duplicate built formula")
        found.add(name)
        require(entry["formula"]["pkg_version"] == build["release"]["formulae"][name],
                "Built package version differs from release manifest")
        require(set(entry["bottle"]["tags"]) == {build["tag"]}, "Built bottle platform differs from runner matrix")
        info = entry["bottle"]["tags"][build["tag"]]
        archive = args.bottles / basename(info["local_filename"])
        require(file_digest(archive) == info["sha256"], "Built archive checksum mismatch")
        version = build["release"]["formulae"][name]
        recipe = (args.output / f"{name}.rb").read_text()
        expected_recipe = private_recipe(recipe, build["release"]["sources"][version])
        with tarfile.open(archive) as tar:
            embedded_recipe = tar.extractfile(f"{name}/{version}/.brew/{name}.rb").read().decode()
        require(without_bottles(embedded_recipe).strip() == without_bottles(expected_recipe).strip(),
                "Embedded build recipe differs from the prepared recipe")
        scan_archive(archive, [os.environ.get("PHP_SECURITY_SOURCE_TOKEN", ""),
                               os.environ.get("HOMEBREW_GITHUB_API_TOKEN", "")])
        build["bottles"].append({"formula": name, "json": path.name,
                                 "json_sha256": file_digest(path), "archive": archive.name,
                                 "sha256": info["sha256"], "inventory": inventory(archive)})
        archive.rename(args.output / archive.name)
        path.rename(args.output / path.name)
    require(found == expected, "Some requested formula bottles were not produced")
    write_json(args.output / "build.json", build)


def collect(args):
    builds = [read_json(path) for path in sorted(args.input.glob("*/build.json"))]
    require(builds, "No private build artifacts")
    first = builds[0]
    tags = {item["tag"] for item in first["release"]["runners"]}
    require(len(builds) == len(tags) and {item["tag"] for item in builds} == tags,
            "Private build is missing a platform or contains duplicates")
    args.output.mkdir(parents=True, exist_ok=False)
    bundle = {key: first[key] for key in ("schema", "repository", "run_id", "commit", "release", "recipes")}
    bundle["bottles"] = []
    for path in sorted(args.input.glob("*/build.json")):
        build = read_json(path)
        for key in ("schema", "repository", "run_id", "commit", "release", "recipes"):
            require(build[key] == first[key], "Private build artifacts have inconsistent provenance")
        require({item["formula"] for item in build["bottles"]} == set(first["release"]["formulae"]),
                "Private build is missing a formula")
        for name, sha in build["recipes"].items():
            recipe = path.parent / f"{name}.rb"
            require(file_digest(recipe) == sha, "Recipe checksum mismatch")
            (args.output / recipe.name).write_bytes(recipe.read_bytes())
        for entry in build["bottles"]:
            entry = dict(entry, tag=build["tag"])
            for key, checksum in (("json", "json_sha256"), ("archive", "sha256")):
                source = path.parent / basename(entry[key])
                require(file_digest(source) == entry[checksum], "Private artifact checksum mismatch")
                require(not (args.output / source.name).exists(), "Duplicate private artifact filename")
                source.rename(args.output / source.name)
            bundle["bottles"].append(entry)
    write_json(args.output / "security-build.json", bundle)


def check_public_source(version, source):
    request = urllib.request.Request(
        f"https://api.github.com/repos/php/php-src/git/ref/tags/php-{version}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "homebrew-php-security-promotion"})
    with urllib.request.urlopen(request, timeout=60) as response:
        require(json.load(response)["ref"] == f"refs/tags/php-{version}", "Public PHP tag mismatch")
    with urllib.request.urlopen(source["public_url"], timeout=120) as response:
        require(stream_digest(response) == source["sha256"],
                "Public source archive differs from the privately built source")


def check_dependencies(documents):
    expected = {}
    for document in documents:
        for entry in document.values():
            for info in entry["bottle"]["tags"].values():
                for dep in info["tab"]["runtime_dependencies"]:
                    require(not dep["full_name"].startswith(PRIVATE_TAP + "/"), "Private runtime dependency")
                    expected.setdefault(dep["full_name"], set()).add(dep["pkg_version"])
    if not expected:
        return
    data = json.loads(subprocess.check_output(
        ["brew", "info", "--json=v2", "--formula", *sorted(expected)], text=True))
    found = set()
    for formula in data["formulae"]:
        name = formula["full_name"]
        require(name in expected, "Unexpected dependency lookup result")
        version = formula["versions"]["stable"]
        if formula["revision"]:
            version += f'_{formula["revision"]}'
        require(expected[name] == {version}, f"Runtime dependency changed since the private build: {name}")
        found.add(name)
    require(found == set(expected), "Missing runtime dependency metadata")


def repack(original, output, name, version, recipe, substitutions, forbidden, source_filenames=None):
    before = inventory(original)
    prefix = f"{name}/{version}/"
    require(all(key.rstrip("/") in (name, f"{name}/{version}") or key.startswith(prefix)
                for key in before), "Archive package identity mismatch")
    formula_path = prefix + f".brew/{name}.rb"
    sbom_path = prefix + "sbom.spdx.json"
    require(formula_path in before and sbom_path in before, "Missing embedded formula or SBOM")
    require(before[formula_path]["type"] == "0" and before[sbom_path]["type"] == "0",
            "Embedded metadata must be regular files")
    changed = set()
    with tarfile.open(original) as incoming, output.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0, compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as outgoing:
                for entry in incoming:
                    member = copy.copy(entry)
                    data = incoming.extractfile(entry).read() if entry.isfile() else None
                    if entry.name == formula_path:
                        data = recipe.encode()
                        changed.add(entry.name)
                    elif entry.name in (sbom_path, prefix + "INSTALL_RECEIPT.json"):
                        metadata = rewrite(json.loads(data), substitutions)
                        if source_filenames:
                            for source_file in metadata.get("files", []):
                                if source_file.get("fileName") == source_filenames[0]:
                                    source_file["fileName"] = source_filenames[1]
                        data = (json.dumps(metadata, indent=2) + "\n").encode()
                        changed.add(entry.name)
                    if data is not None:
                        member.size = len(data)
                    outgoing.addfile(member, io.BytesIO(data) if data is not None else None)
    after = inventory(output)
    require(before.keys() == after.keys(), "Archive member inventory changed")
    for key in before:
        if key not in changed:
            require(before[key] == after[key], "Compiled payload or file metadata changed during promotion")
    scan_archive(output, forbidden)
    return {"unchanged_payload_entries": len(before) - len(changed),
            "changed_metadata_files": sorted(changed),
            "payload_sha256": {key: value["sha256"] for key, value in before.items()
                               if key not in changed and value["sha256"] is not None}}


def promote(args):
    bundle = read_json(args.input / "security-build.json")
    release = bundle["release"]
    # Reuse strict manifest validation before reading any artifact-controlled paths or URLs.
    temporary_manifest = args.input / ".validated-release.json"
    write_json(temporary_manifest, release)
    try:
        manifest(temporary_manifest)
    finally:
        temporary_manifest.unlink()
    require(bundle["schema"] == 1 and bundle["repository"] == PRIVATE_REPO, "Wrong private repository")
    require(bundle["run_id"] == args.run_id and bundle["commit"] == args.build_commit,
            "Private release provenance does not match the successful workflow run")
    require(re.fullmatch(r"[0-9a-f]{40}", args.build_commit), "Invalid private build commit")
    expected = {(name, runner["tag"]) for name in release["formulae"] for runner in release["runners"]}
    actual = [(item["formula"], item["tag"]) for item in bundle["bottles"]]
    require(len(actual) == len(expected) and set(actual) == expected, "Incomplete or duplicate bottle matrix")
    recipes = {}
    for name, version in release["formulae"].items():
        recipe = (args.input / f"{name}.rb").read_text()
        require(digest(recipe.encode()) == bundle["recipes"][name], "Public recipe checksum mismatch")
        current = (args.tap / "Formula" / f"{name}.rb").read_text()
        require(recipe_fingerprint(current) == recipe_fingerprint(recipe),
                f"Public recipe changed since the private build: {name}")
        require(recipe == public_recipe(current, version, release["sources"][version]),
                "Staged recipe differs from the expected public recipe")
        bottle_block = re.search(r"\n  bottle do\n(.*?)\n  end\n", current, re.S)
        required_tags = set(re.findall(r'\b([a-z][a-z0-9_]+):\s*"[0-9a-f]{64}"',
                                       bottle_block[1] if bottle_block else ""))
        require(required_tags <= {runner["tag"] for runner in release["runners"]},
                f"Build matrix omits a currently published platform: {name}")
        old = re.search(r'^  url "https://www.php.net/distributions/php-(\d+\.\d+\.\d+)\.tar.', current, re.M)
        require(old and tuple(map(int, version.split("."))) >= tuple(map(int, old[1].split("."))),
                "Cannot downgrade or replace a non-release formula")
        require(old[1] != version or "\n  bottle do\n" not in current,
                f"This version already has public bottles: {name}; refuse to overwrite")
        recipes[name] = recipe
    for version in sorted(set(release["formulae"].values())):
        check_public_source(version, release["sources"][version])
    documents = []
    rebuilds = {}
    for item in bundle["bottles"]:
        json_path = args.input / basename(item["json"])
        archive = args.input / basename(item["archive"])
        require(file_digest(json_path) == item["json_sha256"] and file_digest(archive) == item["sha256"],
                "Private artifact checksum mismatch")
        require(inventory(archive) == item["inventory"], "Private payload inventory mismatch")
        document = read_json(json_path)
        name, tag = item["formula"], item["tag"]
        require(set(document) == {f"{PRIVATE_TAP}/{name}"}, "Private bottle formula identity mismatch")
        entry = document[f"{PRIVATE_TAP}/{name}"]
        require(entry["formula"]["name"] == name and
                entry["formula"]["pkg_version"] == release["formulae"][name], "Bottle version mismatch")
        require(set(entry["bottle"]["tags"]) == {tag}, "Bottle tag mismatch")
        rebuilds.setdefault(name, set()).add(entry["bottle"].get("rebuild", 0))
        info = entry["bottle"]["tags"][tag]
        require(info["local_filename"] == archive.name and info["sha256"] == item["sha256"],
                "Bottle JSON/archive mismatch")
        documents.append(document)
    require(all(len(values) == 1 for values in rebuilds.values()), "Inconsistent rebuild number across platforms")
    check_dependencies(documents)
    # All matrix, source, recipe, and dependency checks finish before modifying the public tap.
    args.output.mkdir(parents=True, exist_ok=False)
    for name, recipe in recipes.items():
        (args.tap / "Formula" / f"{name}.rb").write_text(recipe)
    git(args.tap, "add", "--", *[f"Formula/{name}.rb" for name in recipes])
    if subprocess.run(["git", "-C", str(args.tap), "diff", "--cached", "--quiet"], check=False).returncode:
        git(args.tap, "commit", "-m", "Prepare PHP security release sources [skip-build]")
    public_commit = git(args.tap, "rev-parse", "HEAD")
    reports = []
    for item, document in zip(bundle["bottles"], documents):
        name, tag = item["formula"], item["tag"]
        version = release["formulae"][name]
        source = release["sources"][version]
        entry = document[f"{PRIVATE_TAP}/{name}"]
        substitutions = [(source["url"], source["public_url"]),
                         (entry["bottle"]["root_url"], ROOT_URL),
                         (PRIVATE_REPO, PUBLIC_REPO), (PRIVATE_TAP, PUBLIC_TAP),
                         (bundle["commit"], public_commit)]
        private_filename = urllib.parse.urlsplit(source["url"]).path.rsplit("/", 1)[-1]
        # SBOM source filenames are independent of downloadLocation.
        original = args.input / item["archive"]
        output = args.output / original.name
        forbidden = [PRIVATE_REPO, PRIVATE_TAP, "PHP_SECURITY_SOURCE_TOKEN",
                     "HOMEBREW_GITHUB_API_TOKEN", "Authorization: Bearer"]
        if source["url"] != source["public_url"]:
            forbidden.append(source["url"])
        # The full source URL is replaced first; only then normalize the SBOM fileName precisely.
        report = repack(original, output, name, version, recipes[name], substitutions, forbidden,
                        (private_filename, source["public_url"].rsplit("/", 1)[-1]))
        with tarfile.open(output) as archive:
            (args.output / (output.name + ".spdx.json")).write_bytes(
                archive.extractfile(f"{name}/{version}/sbom.spdx.json").read())
        document = rewrite(document, substitutions)
        entry = document[f"{PUBLIC_TAP}/{name}"]
        entry["formula"].update(path=f"Library/Taps/{PUBLIC_REPO}/Formula/{name}.rb",
                                tap_git_path=f"Formula/{name}.rb", tap_git_revision=public_commit,
                                tap_git_remote=f"https://github.com/{PUBLIC_REPO}")
        entry["bottle"]["root_url"] = ROOT_URL
        entry["bottle"]["tags"][tag]["sha256"] = file_digest(output)
        serialized = json.dumps(document, indent=2) + "\n"
        require(not any(value in serialized for value in forbidden), "Private data remains in bottle JSON")
        (args.output / item["json"]).write_text(serialized)
        reports.append(dict(report, formula=name, tag=tag, original_sha256=item["sha256"],
                            published_sha256=file_digest(output)))
    write_json(args.output / "promotion.json", {
        "private_run_id": bundle["run_id"], "private_commit": bundle["commit"],
        "public_recipe_commit": public_commit, "formulae": release["formulae"],
        "sources": {version: {"url": source["public_url"], "sha256": source["sha256"]}
                    for version, source in release["sources"].items()}, "bottles": reports,
    })
    print(f"Verified and prepared {len(reports)} bottles; compiled payload is unchanged.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    matrix = commands.add_parser("matrix")
    matrix.add_argument("--manifest", type=Path, required=True)
    for command in ("prepare", "record", "collect", "promote"):
        sub = commands.add_parser(command)
        sub.add_argument("--output", type=Path, required=True)
        if command == "prepare":
            sub.add_argument("--manifest", type=Path, required=True)
            sub.add_argument("--tag", required=True)
        if command in ("prepare", "promote"):
            sub.add_argument("--tap", type=Path, required=True)
        if command == "record":
            sub.add_argument("--bottles", type=Path, required=True)
        if command in ("collect", "promote"):
            sub.add_argument("--input", type=Path, required=True)
        if command == "promote":
            sub.add_argument("--run-id", required=True)
            sub.add_argument("--build-commit", required=True)
    args = parser.parse_args()
    if args.command == "matrix":
        runners = manifest(args.manifest)["runners"]
        for runner in runners:
            if runner["tag"].endswith("_linux"):
                runner["container"] = {"image": "ghcr.io/homebrew/brew:main", "options": "--user=linuxbrew"}
        print(json.dumps({"include": runners}))
    else:
        globals()[args.command](args)


if __name__ == "__main__":
    main()
