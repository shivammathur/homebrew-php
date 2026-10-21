# Prebuilt security release publication

The catalog pins 48 final private releases, 240 bottles, and 576 assets for PHP 5.6–8.5. Each version has four variants; each release contains five platforms. Original runtime results remain 234 passed and six accepted interrupted tests. Asset IDs, sizes, SHA-256 values, revisions, source hashes, and original build provenance are immutable inputs.

## Publish

The `publish-security-release-batch.yml` workflow runs only in `shivammathur/homebrew-php`. Its inputs are `runs` (comma-separated catalog run IDs, blank for all 48) and `ticket` (a unique dispatch identifier). Dispatch publishes immediately; there is no dry-run input. Supply actual backport source URLs in `public-sources.json` before selecting those releases. Official source URLs cannot be overridden, and each public archive must match its recorded public SHA-256. For PHP 5.6–8.1, `public-source-equivalence.json` binds the original built archive to the public tag archive: every member, byte, mode, link, owner, and timestamp matches after removing the repository-specific top-level directory. Both archive hashes remain recorded; compiled payload is unchanged.

Each selected release runs in an isolated worker. It downloads the exact pinned private assets, validates their identity and inventory, rewrites destination metadata while preserving compiled payload bytes, and uploads a complete five-platform package using normal `brew pr-upload` collision checks. Its formula is pushed immediately afterward. Different releases run concurrently with `fail-fast: false`; concurrency protection applies only to duplicate dispatches of the same release. Concurrent formula writes merge current main without force pushes or rewriting recipe commits embedded in bottles.

The job then checks public source availability and SHA-256, current dependency compatibility, package visibility and all five uploaded bottle hashes, style, audit, and SPDX. Those checks cannot hold up other workers. Publication and verification states are recorded separately in `.github/security-promotions/RUNID.json`. A verification failure remains a failure even though the package is already published. Independent installation tests must confirm ordinary public consumption.

The existing `HOMEBREW_GITHUB_API_TOKEN` secret supplies private build access and formula pushes; the workflow token supplies Homebrew package writes. Execution repository, Git origin, and repository visibility must agree. No registry destination is accepted as an input.

## Recover

Artifacts named `security-publication-RUNID-WORKFLOW_RUN_ID` retain validation reports, exact promoted bottles and metadata, uncommitted changes, and Git bundles. If any upload or formula push fails, inspect those artifacts and existing remote state before taking action. Do not blindly rerun an occupied package tag, regenerate candidates with new embedded recipe commits, overwrite valid packages, or rebuild completed bottles. Recover the exact saved candidates and history, then resume only missing writes. Verification follows recovery.

The serial `security_release_batch.py` helper is retained for the original validation workflows and tests. Production dispatch uses `security_publish_parallel.py`. Original private fixtures and URL rehearsals do not establish current public source availability, and accepted runtime interruptions are never relabelled as passes.
