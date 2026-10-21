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
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request


PRIVATE_REPO = "shivammathur/homebrew-php-security"
PUBLIC_REPO = "shivammathur/homebrew-php"
PRIVATE_TAP = "shivammathur/php-security"
PUBLIC_TAP = "shivammathur/php"
BACKPORTS_REPO = "shivammathur/php-src-backports"
TAP_DEPENDENCIES = {"bison@2.7", "autoconf@2.69"}
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


def validate_public_url(version, source):
    url = source.get("public_url")
    if source.get("public_repository") == BACKPORTS_REPO:
        if url is None:
            return  # The public tag is not known until the embargo ends.
        require(isinstance(url, str) and re.fullmatch(
            rf"https://github\.com/{BACKPORTS_REPO}/(?:archive/[A-Za-z0-9._/-]+\.tar\.gz|"
            rf"releases/download/[A-Za-z0-9._-]+/php-{re.escape(version)}\.tar\.gz)", url)
            and "/../" not in url and "/./" not in url,
            "Public backport sources must belong to php-src-backports")
    else:
        require("public_repository" not in source, "Unknown public source repository")
        require(url in [f"https://www.php.net/distributions/php-{version}.tar.{ext}"
                        for ext in ("xz", "gz", "bz2")],
                "Public sources must be official php.net release archives")


def package_version(data, name):
    version = data["formulae"][name]
    revision = data.get("revisions", {}).get(name, 0)
    return f"{version}_{revision}" if revision else version


def manifest(path, formula=""):
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
        validate_public_url(version, source)
    revisions = data.get("revisions", {})
    tap_dependencies = data.get("tap_dependencies", {})
    require(isinstance(tap_dependencies, dict) and set(tap_dependencies) <= TAP_DEPENDENCIES
            and all(isinstance(value, str) and SHA256.fullmatch(value) for value in tap_dependencies.values()),
            "Invalid public tap dependency recipe hashes")
    require(isinstance(revisions, dict) and set(revisions) <= set(data["formulae"]),
            "Invalid formula revision mapping")
    require(all(type(value) is int and value > 0 for value in revisions.values()),
            "Formula revisions must be positive integers")
    for name, version in data["formulae"].items():
        require(FORMULA.fullmatch(name) and version in data["sources"], "Invalid formula/version mapping")
        series = re.search(r"@(\d+\.\d+)", name)
        require(not series or version.startswith(series[1] + "."), "Formula series does not match source")
        require(data["sources"][version].get("public_repository") != BACKPORTS_REPO or name in revisions,
                "Backport builds require an explicit bumped formula revision")
    require(set(data["sources"]) == set(data["formulae"].values()), "Unused or missing source in release manifest")
    tags = [item["tag"] for item in data["runners"]]
    require(len(tags) == len(set(tags)), "Duplicate platform in runner matrix")
    for item in data["runners"]:
        require(re.fullmatch(r"[a-z0-9_]+", item["tag"]), "Invalid bottle tag")
        labels = item["runner"] if isinstance(item["runner"], list) else [item["runner"]]
        require(labels and all(isinstance(label, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", label)
                               for label in labels), "Invalid runner labels")
    if formula:
        require(formula in data["formulae"], "Requested formula is not in the release manifest")
        version = data["formulae"][formula]
        data["formulae"] = {formula: version}
        data["sources"] = {version: data["sources"][version]}
        if "revisions" in data:
            data["revisions"] = {formula: revisions[formula]} if formula in revisions else {}
    return data


def without_bottles(recipe):
    return re.sub(r"\n  bottle do\n.*?\n  end\n", "\n", recipe, flags=re.S)


def recipe_fingerprint(recipe):
    recipe, marker, data = recipe.partition("\n__END__\n")
    recipe = without_bottles(recipe)
    recipe = re.sub(r"^  (?:url|mirror|version|sha256|revision) .*\n", "", recipe, flags=re.M)
    return digest((re.sub(r"\n{3,}", "\n\n", recipe).strip() + marker + data).encode())


def public_recipe(recipe, version, source, revision=0):
    # Ruby DATA may be a unified patch: even an empty context line is significant.
    recipe, marker, data = recipe.partition("\n__END__\n")
    recipe = without_bottles(recipe)
    require(len(re.findall(r'^  url "[^"\n]+"\n', recipe, re.M)) == 1,
            "Expected one simple top-level release URL; prepare the recipe before building")
    recipe = re.sub(r"^  (?:mirror|version) .*\n", "", recipe, flags=re.M)
    if revision:
        recipe, count = re.subn(r"^  revision \d+\n", f"  revision {revision}\n", recipe, flags=re.M)
        require(count == 1, "Expected an existing revision from brew bump-revision")
    else:
        recipe = re.sub(r"^  revision .*\n", "", recipe, flags=re.M)
    url = source.get("public_url") or source["url"]
    recipe = re.sub(r'^  url "[^"\n]+"\n', f'  url "{url}"\n', recipe, flags=re.M)
    recipe, count = re.subn(r'^  sha256 "[0-9a-f]+"\n', f'  sha256 "{source["sha256"]}"\n',
                           recipe, flags=re.M)
    require(count == 1, "Expected one source checksum")
    if source.get("public_repository") == BACKPORTS_REPO:
        recipe = recipe.replace(f'  sha256 "{source["sha256"]}"',
                                f'  version "{version}"\n  sha256 "{source["sha256"]}"', 1)
    else:
        require(version in url, "Source URL/version mismatch")
    return re.sub(r"\n{3,}", "\n\n", recipe) + marker + data


def detected_url_version(url):
    return subprocess.check_output([
        "brew", "ruby", "-e", 'require "version"; puts Version.detect(ARGV.fetch(0)).to_s',
        "--", url], text=True).strip()


PHP_POSTINSTALL = "  post_install_steps do\n    configure_php\n  end\n"
PHP_SETUP_GUARD = '''    # Package setup must not load the user's optional PHP extensions.
    inreplace "pear", /^exec \\$PHP (?:-n )?-C -q /, "exec $PHP -n -C -q ", base: :bin
'''
PHP_SETUP_RESTORE = '    inreplace "pear", "exec $PHP -n -C -q ", "exec $PHP -C -q ", base: :bin\n'
ISOLATED_PHP_POSTINSTALL = ("  post_install_steps do\n" + PHP_SETUP_GUARD +
                          "    configure_php\n" + PHP_SETUP_RESTORE + "  end\n")


def historical_postinstall_recipe(recipe):
    """Undo only our exact publication-time setup guard for build provenance checks."""
    ruby, marker, data = recipe.partition("\n__END__\n")
    pattern = (r"^  post_install_steps do\n" + re.escape(PHP_SETUP_GUARD) + r"(.*?)" +
               re.escape(PHP_SETUP_RESTORE) + r"  end\n")
    ruby = re.sub(pattern, lambda m: "  post_install_steps do\n" + m[1] + "  end\n", ruby, flags=re.M | re.S)
    return ruby + marker + data


def isolate_php_postinstall(recipe):
    ruby, marker, data = historical_postinstall_recipe(recipe).partition("\n__END__\n")
    blocks = list(re.finditer(r"^  post_install_steps do\n(.*?)^  end\n", ruby, re.M | re.S))
    if blocks or "post_install_steps" in ruby or "configure_php" in ruby:
        require(len(blocks) == 1 and ruby.count("  post_install_steps do\n") == 1,
                "Unknown PHP post-install steps; cannot isolate PEAR setup safely")
        block = blocks[0]
        require(("    configure_php\n" in block[1] or '    run "pear", base: :bin,' in block[1]) and
                "exec $PHP -n -C -q " not in block[1],
                "Unknown PHP post-install steps; cannot isolate PEAR setup safely")
        replacement = "  post_install_steps do\n" + PHP_SETUP_GUARD + block[1] + PHP_SETUP_RESTORE + "  end\n"
        ruby = ruby[:block.start()] + replacement + ruby[block.end():]
    return ruby + marker + data


def published_recipe(recipe, version, source, revision=0):
    """Normalize metadata and isolate setup; retain the historical build recipe comparison."""
    result = public_recipe(historical_postinstall_recipe(recipe), version, source, revision)
    if source.get("public_repository") == BACKPORTS_REPO and source.get("public_url"):
        detected = detected_url_version(source["public_url"])
        if detected == version:
            ruby, marker, data = result.partition("\n__END__\n")
            ruby = re.sub(r'^  version "[^"\n]+"\n', "", ruby, flags=re.M)
            result = ruby + marker + data
    elif source.get("public_url"):
        mirrors = re.findall(r'^  mirror "[^"\n]+"\n', recipe.partition("\n__END__\n")[0], re.M)
        mirrors = [re.sub(r"php-\d+\.\d+\.\d+(?=\.tar\.)", "php-" + version, line) for line in mirrors]
        if mirrors:
            result = result.replace(f'  url "{source["public_url"]}"\n',
                                    f'  url "{source["public_url"]}"\n' + "".join(mirrors), 1)
    return isolate_php_postinstall(result)


def accepts_unused_macos_patch_repair(name, tag, original, corrected):
    """Recognize only the old whitespace damage to PHP 5.6's unused Linux DATA."""
    if name not in {"php@5.6", "php@5.6-debug", "php@5.6-zts", "php@5.6-debug-zts"} or \
            tag not in {"x86_64_linux", "arm64_linux"}:
        return False
    old_ruby, old_marker, old_data = original.partition("\n__END__\n")
    new_ruby, new_marker, new_data = corrected.partition("\n__END__\n")
    if not old_marker or not new_marker or old_ruby != new_ruby:
        return False
    # The only access to DATA must be the patch inside the top-level macOS block.
    blocks = re.findall(r"^  on_macos do\n((?:    [^\n]*\n|\n)*)  end$", new_ruby, re.M)
    return (len(re.findall(r"\bDATA\b", new_ruby)) == 1 and
            sum(block.count("    patch :DATA\n") for block in blocks) == 1 and
            old_data == re.sub(r"\n{3,}", "\n\n", new_data))


def private_recipe(recipe, source):
    # Credentials stay in the environment, including when Homebrew embeds this recipe in a bottle.
    for name in TAP_DEPENDENCIES:
        recipe = recipe.replace(f'  depends_on "{PUBLIC_TAP}/{name}"',
                                f'  depends_on "{PRIVATE_TAP}/{name}"')
    auth = source.get("auth", "none")
    replacement = f'  url {json.dumps(source["url"])}\n'
    if auth != "none":
        variable = "HOMEBREW_GITHUB_API_TOKEN" if auth == "github" else "PHP_SECURITY_SOURCE_TOKEN"
        replacement = (f'  url {json.dumps(source["url"])},\n'
                       '      headers: ["Accept: application/octet-stream",\n'
                       f'                "Authorization: Bearer #{{ENV.fetch("{variable}")}}"]\n')
    recipe = recipe.replace(f'  url "{source.get("public_url") or source["url"]}"\n', replacement)
    if re.search(r'^  version "[^"\n]+"$', recipe, re.M):
        return recipe
    version = re.search(r"php-(\d+\.\d+\.\d+)\.tar", source["public_url"])[1]
    filename = urllib.parse.urlsplit(source["url"]).path.rsplit("/", 1)[-1]
    if filename in {f"php-{version}.tar.{ext}" for ext in ("xz", "gz", "bz2")}:
        return recipe
    return recipe.replace(f'  sha256 "{source["sha256"]}"',
                          f'  version "{version}"\n  sha256 "{source["sha256"]}"', 1)


def prepare(args):
    data = manifest(args.manifest, args.formula)
    require(args.tag in {item["tag"] for item in data["runners"]}, "Unexpected build platform")
    require(os.environ.get("GITHUB_REPOSITORY") == PRIVATE_REPO, "Builds must run in the private repository")
    for name, checksum in data.get("tap_dependencies", {}).items():
        require(file_digest(args.tap / "Formula" / f"{name}.rb") == checksum,
                f"Private dependency recipe differs from the recorded public recipe: {name}")
    args.output.mkdir(parents=True, exist_ok=False)
    recipes = {}
    for name, version in data["formulae"].items():
        if data["sources"][version].get("auth") == "bearer":
            require(os.environ.get("PHP_SECURITY_SOURCE_TOKEN"), "PHP_SECURITY_SOURCE_TOKEN is required")
        path = args.tap / "Formula" / f"{name}.rb"
        revision = data.get("revisions", {}).get(name, 0)
        original = path.read_text()
        for dependency in TAP_DEPENDENCIES:
            if f'  depends_on "{PUBLIC_TAP}/{dependency}"' in original:
                require(dependency in data.get("tap_dependencies", {}),
                        f"Missing public dependency recipe hash: {dependency}")
        if revision:
            found_revision = re.search(r"^  revision (\d+)$", original, re.M)
            require(found_revision and int(found_revision[1]) == revision,
                    "Committed formula revision differs from the manifest; run brew bump-revision first")
        recipe = public_recipe(original, version, data["sources"][version], revision)
        recipes[name] = recipe
        (args.output / f"{name}.rb").write_text(recipe)
        path.write_text(private_recipe(recipe, data["sources"][version]))
        path.chmod(0o644)
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


def contains_private(data, forbidden, *, final=True):
    for value in forbidden:
        if not value:
            continue
        needle = value.encode()
        if value in (PRIVATE_REPO, PRIVATE_TAP):
            # A separate test repository may legitimately share the private name's prefix.
            pattern = re.escape(needle) + rb"(?![A-Za-z0-9_-])"
            for match in re.finditer(pattern, data):
                if final or match.end() < len(data):
                    return True
        elif needle in data:
            return True
    return False


def scan_archive(path, forbidden):
    overlap = max((len(value.encode()) for value in forbidden if value), default=1)
    with tarfile.open(path) as archive:
        for member in archive:
            require(not contains_private(member.name.encode(), forbidden), "Private archive member name")
            require(not contains_private(member.linkname.encode(), forbidden), "Private archive link")
            require(not contains_private(json.dumps(member.pax_headers).encode(), forbidden),
                    "Private archive metadata")
            if not member.isfile():
                continue
            stream = archive.extractfile(member)
            tail = b""
            while chunk := stream.read(1024 * 1024):
                block = tail + chunk
                require(not contains_private(block, forbidden, final=False),
                        "Private data remains in bottle payload")
                tail = block[-overlap:]
            require(not contains_private(tail, forbidden), "Private data remains in bottle payload")


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
        require(entry["formula"]["pkg_version"] == package_version(build["release"], name),
                "Built package version differs from release manifest")
        require(set(entry["bottle"]["tags"]) == {build["tag"]}, "Built bottle platform differs from runner matrix")
        info = entry["bottle"]["tags"][build["tag"]]
        archive = args.bottles / basename(info["local_filename"])
        require(file_digest(archive) == info["sha256"], "Built archive checksum mismatch")
        version = build["release"]["formulae"][name]
        recipe = (args.output / f"{name}.rb").read_text()
        expected_recipe = private_recipe(recipe, build["release"]["sources"][version])
        with tarfile.open(archive) as tar:
            embedded_recipe = tar.extractfile(f"{name}/{package_version(build['release'], name)}/.brew/{name}.rb").read().decode()
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


def stash(args):
    """Move the files named by Homebrew's JSON, including bottle rebuild suffixes."""
    build = read_json(args.output / "build.json")
    name = args.formula
    require(name in build["release"]["formulae"], "Unexpected formula to stage")
    version = package_version(build["release"], name)
    tag = build["tag"]
    metadata = args.bottles / f"{name}--{version}.{tag}.bottle.json"
    document = read_json(metadata)
    require(set(document) == {f"{PRIVATE_TAP}/{name}"}, "Bottle formula identity mismatch")
    entry = document[f"{PRIVATE_TAP}/{name}"]
    require(entry["formula"]["name"] == name and entry["formula"]["pkg_version"] == version,
            "Bottle package version mismatch")
    require(set(entry["bottle"]["tags"]) == {tag}, "Bottle platform mismatch")
    info = entry["bottle"]["tags"][tag]
    archive = args.bottles / basename(info["local_filename"])
    require(archive.is_file() and file_digest(archive) == info["sha256"], "Bottle archive checksum mismatch")
    destination = args.output / "bottles"
    destination.mkdir(exist_ok=True)
    require(all(not (destination / path.name).exists() for path in (metadata, archive)),
            "Bottle already staged")
    for path in (metadata, archive):
        shutil.move(path, destination / path.name)


def finalize(args):
    """Preserve completed bottles even when test-bot is interrupted during testing."""
    build = read_json(args.output / "build.json")
    build["build_step_outcome"] = args.outcome
    write_json(args.output / "build.json", build)
    if build.get("bottles"):
        return
    # Work on copies so an interrupted or rejected validation cannot lose raw bottles.
    with tempfile.TemporaryDirectory(prefix="security-record-", dir=args.output.parent) as tmp:
        stage, bottles = Path(tmp) / "stage", Path(tmp) / "bottles"
        stage.mkdir()
        bottles.mkdir()
        for source in (args.output, args.output / "bottles", args.bottles):
            for path in source.glob("*.bottle.*"):
                target = bottles / path.name
                require(not target.exists() or file_digest(target) == file_digest(path),
                        "Conflicting recovery bottle files")
                shutil.copy2(path, target)
        for path in args.output.glob("*.rb"):
            shutil.copy2(path, stage / path.name)
        write_json(stage / "build.json", build)
        record(argparse.Namespace(output=stage, bottles=bottles))
        for path in stage.iterdir():
            if path.name != "build.json":
                shutil.copy2(path, args.output / path.name)
        # The complete manifest is installed last.
        os.replace(stage / "build.json", args.output / "build.json")


def collect(args):
    build_paths = sorted(args.input.glob("*/build.json"))
    # download-artifact extracts a single matching artifact directly into the input root.
    if (args.input / "build.json").is_file():
        build_paths.insert(0, args.input / "build.json")
    reuse_run = getattr(args, "reuse_run", "")
    if reuse_run:
        current = [path for path in build_paths
                   if str(read_json(path)["run_id"]) == os.environ.get("GITHUB_RUN_ID")
                   and read_json(path)["commit"] == os.environ.get("GITHUB_SHA")]
        require(current, "Recovery is missing artifacts from its own run and commit")
        # The recovery's manifest/recipe is canonical, regardless of platform sort order.
        build_paths = [current[0], *[path for path in build_paths if path != current[0]]]
    builds = [read_json(path) for path in build_paths]
    require(builds, "No private build artifacts")
    first = builds[0]
    tags = {item["tag"] for item in first["release"]["runners"]}
    require(len(builds) == len(tags) and {item["tag"] for item in builds} == tags,
            "Private build is missing a platform or contains duplicates")
    args.output.mkdir(parents=True, exist_ok=False)
    bundle = {key: first[key] for key in ("schema", "repository", "run_id", "commit", "release", "recipes")}
    if reuse_run:
        require(re.fullmatch(r"[0-9]+", reuse_run) and
                re.fullmatch(r"[0-9a-f]{40}", args.reuse_commit), "Invalid reuse provenance")
        require(os.environ.get("GITHUB_REPOSITORY") == PRIVATE_REPO, "Recovery must remain private")
        bundle.update(run_id=os.environ["GITHUB_RUN_ID"], commit=os.environ["GITHUB_SHA"])
        allowed = {(reuse_run, args.reuse_commit), (bundle["run_id"], bundle["commit"])}
    bundle["bottles"] = []
    for path in build_paths:
        build = read_json(path)
        keys = ("schema", "repository") if reuse_run else (
            "schema", "repository", "run_id", "commit", "release", "recipes")
        for key in keys:
            require(build[key] == first[key], "Private build artifacts have inconsistent provenance")
        if reuse_run:
            require((str(build["run_id"]), build["commit"]) in allowed,
                    "Unapproved recovery build provenance")
            original_release = dict(build["release"])
            current_release = dict(first["release"])
            original_dependencies = original_release.pop("tap_dependencies", {})
            current_dependencies = current_release.pop("tap_dependencies", {})
            require(original_release == current_release and
                    original_dependencies.items() <= current_dependencies.items() and
                    set(current_dependencies) <= TAP_DEPENDENCIES and
                    all(SHA256.fullmatch(value) for value in current_dependencies.values()),
                    "Private build artifacts have inconsistent release manifests")
        require({item["formula"] for item in build["bottles"]} == set(first["release"]["formulae"]),
                "Private build is missing a formula")
        require(set(build["recipes"]) == set(first["recipes"]), "Private build is missing a recipe")
        repaired = {}
        for name, sha in build["recipes"].items():
            recipe = path.parent / f"{name}.rb"
            require(file_digest(recipe) == sha, "Recipe checksum mismatch")
            canonical = build_paths[0].parent / recipe.name
            require(file_digest(canonical) == first["recipes"][name], "Canonical recipe checksum mismatch")
            if sha != first["recipes"][name]:
                require(reuse_run and accepts_unused_macos_patch_repair(
                    name, build["tag"], recipe.read_text(), canonical.read_text()),
                    "Private build artifacts have inconsistent recipes")
                repaired[name] = sha
            (args.output / recipe.name).write_bytes(canonical.read_bytes())
        for entry in build["bottles"]:
            entry = dict(entry, tag=build["tag"])
            if reuse_run:
                entry["build_provenance"] = {key: build[key] for key in ("repository", "run_id", "commit")}
            if entry["formula"] in repaired:
                entry["build_recipe_sha256"] = repaired[entry["formula"]]
                entry["recipe_normalization"] = "preserve-unused-macos-patch-data"
            if "build_step_outcome" in build:
                entry["build_step_outcome"] = build["build_step_outcome"]
            for key, checksum in (("json", "json_sha256"), ("archive", "sha256")):
                source = path.parent / basename(entry[key])
                require(file_digest(source) == entry[checksum], "Private artifact checksum mismatch")
                require(not (args.output / source.name).exists(), "Duplicate private artifact filename")
                source.rename(args.output / source.name)
            bundle["bottles"].append(entry)
    write_json(args.output / "security-build.json", bundle)


def check_public_source(version, source):
    validate_public_url(version, source)
    require(source.get("public_url"), "The published backport URL is required before promotion")
    if source.get("public_repository") != BACKPORTS_REPO:
        headers = {"Accept": "application/vnd.github+json", "User-Agent": "homebrew-php-security-promotion"}
        if os.environ.get("GH_TOKEN"):
            headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
        request = urllib.request.Request(
            f"https://api.github.com/repos/php/php-src/git/ref/tags/php-{version}", headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            require(json.load(response)["ref"] == f"refs/tags/php-{version}", "Public PHP tag mismatch")
    with urllib.request.urlopen(source["public_url"], timeout=120) as response:
        require(stream_digest(response) == source["sha256"],
                "Public source archive differs from the privately built source")


def check_dependencies(documents, tap_dependencies=None, *, allow_newer_certificates=False):
    expected = {}
    for document in documents:
        for entry in document.values():
            for info in entry["bottle"]["tags"].values():
                for dep in info["tab"]["runtime_dependencies"]:
                    name = dep["full_name"]
                    if name.startswith(PRIVATE_TAP + "/"):
                        short_name = name.removeprefix(PRIVATE_TAP + "/")
                        require(short_name in (tap_dependencies or {}), "Private runtime dependency")
                        name = f"{PUBLIC_TAP}/{short_name}"
                    expected.setdefault(name, set()).add(dep["pkg_version"])
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
        newer_certificates = (allow_newer_certificates and name == "ca-certificates"
                              and re.fullmatch(r"\d{4}-\d{2}-\d{2}", version)
                              and all(re.fullmatch(r"\d{4}-\d{2}-\d{2}", old) and old <= version
                                      for old in expected[name]))
        require(expected[name] == {version} or newer_certificates,
                f"Runtime dependency changed since the private build: {name}")
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
    if PHP_SETUP_GUARD in recipe:
        require(prefix + "bin/pear" in before and before[prefix + "bin/pear"]["type"] == "0",
                "Missing PEAR launcher for isolated package setup")
    changed = set()
    with tarfile.open(original) as incoming, output.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0, compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as outgoing:
                for entry in incoming:
                    member = copy.copy(entry)
                    data = incoming.extractfile(entry).read() if entry.isfile() else None
                    if entry.name == prefix + "bin/pear" and PHP_SETUP_GUARD in recipe:
                        require(data is not None and data.count(b"exec $PHP -C -q ") == 1,
                                "Unexpected PEAR launcher; cannot isolate package setup safely")
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


def apply_source_archive_equivalence(version, source, proof):
    """Accept only a pinned comparison of identical source members in renamed archives."""
    require(source.get("public_repository") == BACKPORTS_REPO, "Only backport archives may be remapped")
    require(proof.get("schema") == 1 and proof.get("version") == version and
            proof.get("php_version") == version and proof.get("source_contents_identical") is True,
            "Source archive equivalence/version mismatch")
    tag = proof.get("tag_sha", "")
    require(re.fullmatch(r"[a-f0-9]{40}", tag) and
            re.fullmatch(r"[a-f0-9]{40}", proof.get("commit", "")), "Invalid source tag identity")
    expected_url = f"https://github.com/{BACKPORTS_REPO}/archive/{tag}.tar.gz"
    require(source.get("public_url") == proof.get("public_url") == expected_url,
            "Source archive equivalence URL mismatch")
    require(proof.get("private_archive_sha256") == source["sha256"] and
            SHA256.fullmatch(proof.get("public_archive_sha256", "")),
            "Source archive equivalence checksum mismatch")
    require(SHA256.fullmatch(proof.get("private_inventory_sha256", "")) and
            proof["private_inventory_sha256"] == proof.get("public_inventory_sha256") and
            type(proof.get("entries")) is int and proof["entries"] > 0,
            "Source archive member inventories differ")
    require(proof.get("private_root") == f"shivammathur-php-src-backports-security-{tag}" and
            proof.get("public_root") == f"php-src-backports-{tag}",
            "Unexpected source archive root change")
    source["sha256"] = proof["public_archive_sha256"]


def promote(args):
    bundle = read_json(args.input / "security-build.json")
    staged_release = bundle["release"]
    release = copy.deepcopy(staged_release)
    if getattr(args, "public_sources", None):
        urls = read_json(args.public_sources)
        require(isinstance(urls, dict) and set(urls) <= set(release["sources"]),
                "Public source overrides must name staged source versions")
        for version, url in urls.items():
            require(release["sources"][version].get("public_repository") == BACKPORTS_REPO,
                    "Only deferred backport URLs can be supplied at promotion")
            release["sources"][version]["public_url"] = url
    source_equivalence = getattr(args, "source_archive_equivalence", {})
    require(isinstance(source_equivalence, dict) and set(source_equivalence) <= set(release["sources"]),
            "Source archive equivalence must name staged source versions")
    for version, proof in source_equivalence.items():
        apply_source_archive_equivalence(version, release["sources"][version], proof)
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
    for name, checksum in release.get("tap_dependencies", {}).items():
        require(file_digest(args.tap / "Formula" / f"{name}.rb") == checksum,
                f"Public dependency recipe changed since the private build: {name}")
    expected = {(name, runner["tag"]) for name in release["formulae"] for runner in release["runners"]}
    actual = [(item["formula"], item["tag"]) for item in bundle["bottles"]]
    require(len(actual) == len(expected) and set(actual) == expected, "Incomplete or duplicate bottle matrix")
    recipes = {}
    for name, version in release["formulae"].items():
        recipe = (args.input / f"{name}.rb").read_text()
        require(digest(recipe.encode()) == bundle["recipes"][name], "Public recipe checksum mismatch")
        current = (args.tap / "Formula" / f"{name}.rb").read_text()
        historical_current = historical_postinstall_recipe(current)
        require(recipe_fingerprint(historical_current) == recipe_fingerprint(recipe),
                f"Public recipe changed since the private build: {name}")
        revision = release.get("revisions", {}).get(name, 0)
        require(recipe == public_recipe(historical_current, version, staged_release["sources"][version], revision),
                "Staged recipe differs from the expected public recipe")
        bottle_block = re.search(r"\n  bottle do\n(.*?)\n  end\n", current, re.S)
        required_tags = set(re.findall(r'\b([a-z][a-z0-9_]+):\s*"[0-9a-f]{64}"',
                                       bottle_block[1] if bottle_block else ""))
        require(required_tags <= {runner["tag"] for runner in release["runners"]},
                f"Build matrix omits a currently published platform: {name}")
        final_recipe = published_recipe(current, version, release["sources"][version], revision)
        if release["sources"][version].get("public_repository") == BACKPORTS_REPO:
            require(re.search(rf'^  url "https://github.com/{BACKPORTS_REPO}/', current, re.M),
                    "Backport promotion requires an existing public backport formula")
            old = re.search(r'^  version "([^"]+)"$', current, re.M)
            old_revision = re.search(r'^  revision (\d+)$', current, re.M)
            old_version = old[1] if old else detected_url_version(
                re.search(r'^  url "([^"\n]+)"$', current, re.M)[1])
            require(old_version == version, "Backport promotion must preserve the upstream version")
            current_revision = int(old_revision[1]) if old_revision else 0
            already_prepared = (current_revision == revision and bottle_block is None and
                                current == final_recipe)
            require(revision == current_revision + 1 or already_prepared,
                    "Backport promotion requires exactly one revision bump")
        else:
            old = re.search(r'^  url "https://www.php.net/distributions/php-(\d+\.\d+\.\d+)\.tar.', current, re.M)
            require(old and tuple(map(int, version.split("."))) >= tuple(map(int, old[1].split("."))),
                    "Cannot downgrade or replace a non-release formula")
            require(old[1] != version or "\n  bottle do\n" not in current,
                    f"This version already has public bottles: {name}; refuse to overwrite")
        recipes[name] = final_recipe
    defer_release_checks = getattr(args, "defer_release_checks", False)
    require(type(defer_release_checks) is bool, "Invalid release check mode")
    if not defer_release_checks:
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
                entry["formula"]["pkg_version"] == package_version(release, name), "Bottle version mismatch")
        require(set(entry["bottle"]["tags"]) == {tag}, "Bottle tag mismatch")
        rebuilds.setdefault(name, set()).add(entry["bottle"].get("rebuild", 0))
        info = entry["bottle"]["tags"][tag]
        require(info["local_filename"] == archive.name and info["sha256"] == item["sha256"],
                "Bottle JSON/archive mismatch")
        documents.append(document)
    require(all(len(values) == 1 for values in rebuilds.values()), "Inconsistent rebuild number across platforms")
    if not defer_release_checks:
        check_dependencies(documents, release.get("tap_dependencies", {}))
    # Artifact identity and payload preservation always apply. The parallel publisher
    # performs live-source and current-dependency checks after package publication.
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
                         (item.get("build_provenance", bundle)["commit"], public_commit)]
        if version in source_equivalence:
            substitutions.append((staged_release["sources"][version]["sha256"], source["sha256"]))
        private_filename = urllib.parse.urlsplit(source["url"]).path.rsplit("/", 1)[-1]
        # SBOM source filenames are independent of downloadLocation.
        original = args.input / item["archive"]
        output = args.output / original.name
        forbidden = [PRIVATE_REPO, PRIVATE_TAP, "PHP_SECURITY_SOURCE_TOKEN",
                     "HOMEBREW_GITHUB_API_TOKEN", "Authorization: Bearer"]
        if source["url"] != source["public_url"]:
            forbidden.append(source["url"])
        # The full source URL is replaced first; only then normalize the SBOM fileName precisely.
        pkg_version = package_version(release, name)
        report = repack(original, output, name, pkg_version, recipes[name], substitutions, forbidden,
                        (private_filename, source["public_url"].rsplit("/", 1)[-1]))
        with tarfile.open(output) as archive:
            (args.output / (output.name + ".spdx.json")).write_bytes(
                archive.extractfile(f"{name}/{pkg_version}/sbom.spdx.json").read())
        document = rewrite(document, substitutions)
        entry = document[f"{PUBLIC_TAP}/{name}"]
        entry["formula"].update(path=f"Library/Taps/{PUBLIC_REPO}/Formula/{name}.rb",
                                tap_git_path=f"Formula/{name}.rb", tap_git_revision=public_commit,
                                tap_git_remote=f"https://github.com/{PUBLIC_REPO}")
        entry["bottle"]["root_url"] = ROOT_URL
        entry["bottle"]["tags"][tag]["sha256"] = file_digest(output)
        serialized = json.dumps(document, indent=2) + "\n"
        require(not contains_private(serialized.encode(), forbidden), "Private data remains in bottle JSON")
        (args.output / item["json"]).write_text(serialized)
        reports.append(dict(report, formula=name, tag=tag, original_sha256=item["sha256"],
                            published_sha256=file_digest(output)))
    write_json(args.output / "promotion.json", {
        "private_run_id": bundle["run_id"], "private_commit": bundle["commit"],
        "release_checks_deferred": defer_release_checks,
        "public_recipe_commit": public_commit, "formulae": release["formulae"],
        "revisions": release.get("revisions", {}),
        "sources": {version: {"url": source["public_url"], "sha256": source["sha256"]}
                    for version, source in release["sources"].items()},
        "source_archive_equivalence": source_equivalence, "bottles": reports,
    })
    print(f"Verified and prepared {len(reports)} bottles; compiled payload is unchanged.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    matrix = commands.add_parser("matrix")
    matrix.add_argument("--manifest", type=Path, required=True)
    matrix.add_argument("--formula", default="", help="Build only this formula from the manifest")
    matrix.add_argument("--tags", default="", help="Comma-separated platform tags to rebuild")
    package = commands.add_parser("package-version")
    package.add_argument("--manifest", type=Path, required=True)
    package.add_argument("--formula", required=True)
    for command in ("prepare", "record", "stash", "finalize", "collect", "promote"):
        sub = commands.add_parser(command)
        sub.add_argument("--output", type=Path, required=True)
        if command == "prepare":
            sub.add_argument("--manifest", type=Path, required=True)
            sub.add_argument("--formula", default="", help="Build only this formula from the manifest")
            sub.add_argument("--tag", required=True)
        if command in ("prepare", "promote"):
            sub.add_argument("--tap", type=Path, required=True)
        if command in ("record", "stash", "finalize"):
            sub.add_argument("--bottles", type=Path, required=True)
        if command == "stash":
            sub.add_argument("--formula", required=True)
        if command == "finalize":
            sub.add_argument("--outcome", choices=("success", "failure", "cancelled", "skipped"), required=True)
        if command == "collect":
            sub.add_argument("--reuse-run", default="")
            sub.add_argument("--reuse-commit", default="")
        if command in ("collect", "promote"):
            sub.add_argument("--input", type=Path, required=True)
        if command == "promote":
            sub.add_argument("--run-id", required=True)
            sub.add_argument("--build-commit", required=True)
            sub.add_argument("--public-sources", type=Path,
                             help="JSON mapping staged PHP versions to their published backport archive URLs")
    args = parser.parse_args()
    if args.command == "matrix":
        runners = manifest(args.manifest, args.formula)["runners"]
        if args.tags:
            tags = args.tags.split(",")
            require(len(tags) == len(set(tags)) and set(tags) <= {r["tag"] for r in runners},
                    "Unknown or duplicate requested platform")
            runners = [r for r in runners if r["tag"] in tags]
        for runner in runners:
            if runner["tag"].endswith("_linux"):
                runner["container"] = {"image": "ghcr.io/homebrew/brew:main", "options": "--user=linuxbrew"}
        print(json.dumps({"include": runners}))
    elif args.command == "package-version":
        print(package_version(manifest(args.manifest, args.formula), args.formula))
    else:
        globals()[args.command](args)


if __name__ == "__main__":
    main()
