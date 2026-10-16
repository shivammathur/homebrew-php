# Prebuilt PHP security releases

`shivammathur/homebrew-php-security` is an independent private copy of this tap with its Git history preserved. GitHub does not allow a private fork of a public repository. The private copy has only explicit security-build and validation workflows; the public tap's scheduled updates and publishers are removed there.

Private builds use `brew test-bot`, retain the tarballs **and** bottle JSON, and save a complete build to a private GitHub release. Publication verifies the announced PHP source and changes packaging metadata without recompiling the payload. The public workflow defaults to validation only.

## Before the embargoed build

1. Register dedicated private macOS runners with `homebrew-php-security`. The example matches the public tap's Golden Gate, Tahoe, and Sequoia ARM64 platforms. Repository-level runners are not shared automatically. Keep embargoed sources, caches, and logs isolated from public CI jobs. Linux jobs use the same `ghcr.io/homebrew/brew:main` container as public CI, on both architectures.
2. Refresh `Formula/` and `Aliases/` from public `main` in the private copy. For example, `git fetch upstream main` followed by `git restore --source=upstream/main -- Formula Aliases`. Keep the private workflow changes when updating the copy.
3. Copy `security/release.example.json` to `security/release.json` **in the private repository**. Replace the illustrative version, source URLs, asset ID, and checksum. Add each PHP series and each intended normal/debug/ZTS variant explicitly. The example is deliberately invalid until completed.
4. Commit the manifest and any recipe changes privately. Every formula is prepared with the new final source version, revision zero, and no old bottle block. Other recipe contents are preserved. If those other contents differ from the public recipe, land the same recipe changes publicly after announcement before promotion.

Authentication is selected per source:

- `"auth": "github"`: the URL must be a release-asset API URL in `homebrew-php-security`. The job's own `GITHUB_TOKEN` is used. Upload the source archive to a private release and use the asset's API `url`, not its browser download URL.
- `"auth": "bearer"`: set the private repository secret `PHP_SECURITY_SOURCE_TOKEN`. It is used only for sources explicitly selecting this mode.
- `"auth": "none"`: use an already-authorized private URL, such as a signed URL, with no Authorization header.

The public URL must be the corresponding `https://www.php.net/distributions/php-X.Y.Z.tar.xz` (or `.gz`/`.bz2`) archive. Its bytes must eventually match the private source checksum.

## Build and hold privately

```sh
gh workflow run security-build.yml \
  --repo shivammathur/homebrew-php-security --ref main \
  -f manifest=security/release.json -F timeout=180
```

Follow the run to completion. Only a complete successful matrix creates `security-build-RUN_ID` in the private repository. It contains the bottles, JSON, canonical public recipes, exact payload inventories, and build provenance. This private release persists beyond Actions artifact retention. No public package upload occurs during this build.

## Promote after public announcement

Merge the public `feature/security-bottle-promotion` branch into `main` before using the publisher. GitHub requires a manually dispatched workflow on the default branch. The public repository's existing `HOMEBREW_GITHUB_API_TOKEN` secret needs read access to `homebrew-php-security` and write access to the public PHP GHCR packages. No new credential is copied to the private repository.

Validate first:

```sh
gh workflow run publish-security-bottles.yml \
  --repo shivammathur/homebrew-php --ref main \
  -f private_run_id=RUN_ID -f target_branch=main -F publish=false
```

Then publish the verified build:

```sh
gh workflow run publish-security-bottles.yml \
  --repo shivammathur/homebrew-php --ref main \
  -f private_run_id=RUN_ID -f target_branch=main -F publish=true
```

Publishing requires every `php-X.Y.Z` tag to exist in `php/php-src` and independently downloads every official source archive to compare SHA-256. It also checks:

- The private run succeeded in `security-build.yml` and matches the staged commit/run ID.
- Every requested formula and platform is present exactly once; the matrix covers the formula's currently published platforms.
- The source, recipe, package version, bottle JSON, archives, and complete payload inventories agree. A recipe change beyond the source/version/bottle fields rejects promotion.
- Recorded runtime dependency package versions still match the currently available formulae. Rebuild if these have moved; there is no bypass that silently accepts dependency drift.
- Private source URLs, tap identifiers, and authentication expressions have been removed from public artifacts. All non-metadata payload bytes, modes, links, timestamps, and archive entries are unchanged.
- Homebrew can merge the bottle JSON, and formula style/audit checks pass.

The publisher updates the embedded `.brew` recipe and SBOM, rewrites bottle JSON for `shivammathur/php`, and recalculates archive checksums. It uses `brew pr-upload` to publish to the existing PHP GHCR location, then pushes the source and bottle commits. The final commit records a compact promotion report and uses `[skip-build]`, so the main build workflow does not compile the release again. Publishing to `main` also dispatches the existing default-branch synchronization workflow.

`publish=false` uploads verified candidates as workflow artifacts and does not upload GHCR packages or push the public branch. It still requires public tags and matching source archives. A previously bottled version is rejected to avoid replacing an existing release.

## Failure and recovery

Failed source, provenance, recipe, dependency, or matrix checks stop before any public tap commit is prepared. Later validation failures never upload packages. If an upload or push fails, inspect the complete failure before retrying: registry uploads are not transactional. The workflow retains verified candidate artifacts and, after successful promotion preparation, a Git bundle of the prepared commits. Recover those commits and artifacts if publication only partially completed; do not force-push over concurrent public changes.

The automated checks cover successful two-platform promotion and rejection of incomplete/duplicate matrices, changed recipes/dependencies, bad provenance, corrupt archives/JSON, source mismatches, unsafe archive paths, and leaked private payload strings. Real PHP release builds and downstream installation checks are still required for each staged security release.
