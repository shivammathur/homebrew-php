"""Pinned release promotion: private rehearsal or live-source publication, never cross-repository writes."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import functools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from types import SimpleNamespace

import security_bottles as s
import verify_security_packages

TEST_REPO = 'shivammathur/homebrew-php-security-test'
PRODUCTION_REPO = 'shivammathur/homebrew-php'
PLATFORMS = {'arm64_sequoia', 'arm64_tahoe', 'arm64_golden_gate', 'x86_64_linux', 'arm64_linux'}
HERE = Path(__file__).resolve().parents[1]


def command(*args, cwd=None):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


@functools.lru_cache(maxsize=None)
def api(path):
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def now():
    return datetime.now(timezone.utc).isoformat()


def destination(tap, mode):
    repo = os.environ.get('GITHUB_REPOSITORY')
    s.require(repo in {TEST_REPO, PRODUCTION_REPO}, 'Unsupported execution repository')
    s.require(mode == 'public' or repo == TEST_REPO, 'Rehearsal is restricted to the private test repository')
    s.require(s.git(tap, 'remote', 'get-url', 'origin') in
              (f'https://github.com/{repo}', f'https://github.com/{repo}.git'), 'Destination origin mismatch')
    live = api(f'repos/{repo}')
    s.require(live['full_name'] == repo and live['private'] == (repo == TEST_REPO),
              'Destination repository visibility changed')
    tap_name = repo.replace('homebrew-', '', 1)
    return repo, tap_name, 'https://ghcr.io/v2/' + tap_name


def load_catalog(path):
    catalog = s.read_json(path)
    s.require(catalog['schema'] == 1 and catalog['repository'] == s.PRIVATE_REPO, 'Wrong catalog')
    releases = catalog['releases']
    s.require(len(releases) == 48 and len({r['formula'] for r in releases}) == 48 and
              len({r['run_id'] for r in releases}) == 48 and len(catalog['sources']) == 12,
              'Catalog must contain exactly 48 unique final releases and 12 sources')
    outcomes = Counter()
    for r in releases:
        s.require(s.FORMULA.fullmatch(r['formula']) and s.VERSION.fullmatch(r['version']) and
                  re.fullmatch(r'[0-9]+', r['run_id']) and re.fullmatch(r'[a-f0-9]{40}', r['commit']),
                  'Invalid release identity')
        s.require(len(r['assets']) == 12 and all(s.basename(n) and s.SHA256.fullmatch(a['sha256'])
                  and type(a['id']) is int and a['size'] > 0 for n, a in r['assets'].items()),
                  'Invalid pinned assets')
        s.require(len(r['platforms']) == 5 and {p['tag'] for p in r['platforms']} == PLATFORMS,
                  'Incomplete platform matrix')
        for p in r['platforms']:
            outcomes[p['runtime_test']] += 1
            s.require(p['provenance']['repository'] == s.PRIVATE_REPO and
                      r['assets'][p['archive']]['sha256'] == p['sha256'], 'Bottle provenance mismatch')
            if p['runtime_test'] == 'interrupted':
                q = p.get('accepted_interruption', {})
                s.require(q.get('sha256') == p['sha256'] and q.get('commit') == p['provenance']['commit']
                          and q.get('formula') == r['formula'] and q.get('reason') and
                          type(q.get('original_cancelled_job')) is int, 'Missing exact interruption approval')
            elif p['build_step_outcome'] == 'failure':
                q = p.get('post_test_failure', {})
                s.require(q.get('sha256') == p['sha256'] and q.get('commit') == p['provenance']['commit']
                          and q.get('formula') == r['formula'] and q.get('json_sha256') == p['json_sha256']
                          and q.get('runtime_test') == 'passed' and s.SHA256.fullmatch(q.get('log_sha256', '')),
                          'Missing exact post-test failure proof')
            else:
                s.require(p['runtime_test'] == 'passed' and p['build_step_outcome'] in (None, 'success'),
                          'Unapproved runtime outcome')
    s.require(dict(outcomes) == {'passed': 234, 'interrupted': 6}, 'Runtime accounting mismatch')
    return catalog


def verify_assets(row, path):
    s.require({p.name for p in path.iterdir()} == set(row['assets']), 'Incomplete or unexpected assets')
    for name, expected in row['assets'].items():
        file = path / name
        s.require(file.is_file() and not file.is_symlink() and file.stat().st_size == expected['size'] and
                  s.file_digest(file) == expected['sha256'], f'Changed release asset: {name}')
    bundle = s.read_json(path / 'security-build.json')
    s.require(bundle['run_id'] == row['run_id'] and bundle['commit'] == row['commit'] and
              bundle['repository'] == s.PRIVATE_REPO and
              bundle['release']['formulae'] == {row['formula']: row['version']} and
              bundle['release'].get('revisions', {}).get(row['formula'], 0) == row['revision'],
              'Release manifest differs from pinned validation')
    s.require(len(bundle['bottles']) == 5, 'Wrong bottle count')
    for p in row['platforms']:
        matches = [b for b in bundle['bottles'] if b['tag'] == p['tag']]
        s.require(len(matches) == 1, 'Duplicate or missing platform')
        b = matches[0]
        provenance = b.get('build_provenance', {k: bundle[k] for k in ('repository', 'run_id', 'commit')})
        s.require(provenance == p['provenance'] and b['sha256'] == p['sha256'] and
                  b['json_sha256'] == p['json_sha256'] and b.get('build_step_outcome') == p['build_step_outcome'],
                  'Runtime approval is not bound to this bottle')
    return bundle


def fetch(row, path):
    s.require(api(f'repos/{s.PRIVATE_REPO}')['private'] is True, 'Build repository must remain private')
    # A historical Actions failure is not relabelled as success. Eligibility comes from
    # the independently verified, hash-pinned assets and exact per-bottle runtime evidence.
    run = api(f"repos/{s.PRIVATE_REPO}/actions/runs/{row['run_id']}")
    s.require(run['head_sha'] == row['commit'] and run['status'] == 'completed' and
              run['repository']['full_name'] == s.PRIVATE_REPO and
              run['path'] == '.github/workflows/security-build.yml', 'Build run changed')
    release = api(f"repos/{s.PRIVATE_REPO}/releases/tags/security-build-{row['run_id']}")
    s.require(not release['draft'] and release['target_commitish'] == row['commit'], 'Release commit changed')
    live = {a['name']: a for a in release['assets']}
    s.require(len(release['assets']) == 12 and set(live) == set(row['assets']), 'Live asset matrix changed')
    for name, a in row['assets'].items():
        s.require(live[name]['state'] == 'uploaded' and live[name]['id'] == a['id'] and
                  live[name]['size'] == a['size'] and live[name]['digest'] == 'sha256:' + a['sha256'],
                  'Live asset differs from verified release')
    observed = now()
    path.mkdir(parents=True, exist_ok=False)
    command('gh', 'release', 'download', 'security-build-' + row['run_id'], '--repo', s.PRIVATE_REPO,
            '--dir', path)
    verify_assets(row, path)
    return {'observed_at': observed, 'actions_conclusion': run['conclusion'], 'assets': 12}


def source_check(version, source, catalog, mode, cache):
    pin = catalog['sources'][version]
    s.require(source['sha256'] == pin['sha256'], 'Unpinned source bytes')
    s.validate_public_url(version, source)
    s.require(source.get('public_url'), 'Final public source URL is required')
    if mode == 'public':
        s.check_public_source(version, source)
        return {'version': version, 'sha256': pin['sha256'], 'url': source['public_url'],
                'public_availability_verified': True, 'observed_at': now()}
    fixture = pin['fixture']
    s.require(fixture['repository'] == TEST_REPO and fixture['sha256'] == pin['sha256'], 'Wrong private fixture')
    cache.mkdir(parents=True, exist_ok=True)
    file = cache / pin['fixture_name']
    if not file.exists():
        with file.open('wb') as output:
            subprocess.run(['gh', 'api', '--allow-escape-sequences',
                            f"repos/{TEST_REPO}/releases/assets/{fixture['asset_id']}",
                            '-H', 'Accept: application/octet-stream'], stdout=output, check=True)
    s.require(file.stat().st_size == fixture['size'] and s.file_digest(file) == pin['sha256'],
              'Private fixture differs from built source')
    return {'version': version, 'sha256': pin['sha256'], 'url': source['public_url'],
            'public_availability_verified': False, 'fixture_asset_id': fixture['asset_id']}


def select(catalog, versions, runs):
    s.require(not (versions and runs), 'Select versions or runs, not both')
    values = (versions or runs).split(',') if versions or runs else []
    key = 'version' if versions else 'run_id'
    s.require(len(values) == len(set(values)) and set(values) <= {r[key] for r in catalog['releases']},
              'Unknown or duplicate release selection')
    return [r for r in catalog['releases'] if not values or r[key] in values]


def prepare(args):
    catalog = load_catalog(args.catalog)
    rows = select(catalog, args.versions, args.runs)
    repo, tap_name, root_url = destination(args.tap, args.mode)
    s.require(not args.publish or args.mode == 'public', 'Publication requires real public source verification')
    s.require(not s.git(args.tap, 'status', '--porcelain'), 'Start with a clean tap')
    base = s.git(args.tap, 'rev-parse', 'HEAD')
    args.output.mkdir(parents=True, exist_ok=False)
    if args.mode == 'rehearsal':
        # Baseline reset is confined to the test checkout. Previously published test packages
        # are never touched; no publication step exists in rehearsal mode.
        for row in rows:
            target = args.tap / 'Formula' / (row['formula'] + '.rb')
            target.write_bytes(subprocess.check_output(['git', '-C', str(args.tap), 'show',
                                                      catalog['baseline_commit'] + ':Formula/' + target.name]))
        command('git', 'add', '--', 'Formula', cwd=args.tap)
        if subprocess.run(['git', 'diff', '--cached', '--quiet'], cwd=args.tap).returncode:
            command('git', 'commit', '-m', 'Prepare isolated rehearsal baseline [skip-build]', cwd=args.tap)
    urls = s.read_json(args.public_sources)
    s.require(set(urls) == set(catalog['sources']), 'Public source map must cover all 12 versions')
    verified_sources = {}
    if args.mode == 'public':
        for version in {r['version'] for r in rows}:
            pin = catalog['sources'][version]
            src = {'sha256': pin['sha256'], 'public_url': urls[version]}
            if pin['public_repository']:
                src['public_repository'] = pin['public_repository']
            s.require(src['public_url'], f'Final public source URL is missing: {version}')
            verified_sources[version] = source_check(version, src, catalog, 'public', args.output / 'sources')
    results = []
    s.PUBLIC_REPO, s.PUBLIC_TAP, s.ROOT_URL = repo, tap_name, root_url
    original_source_check, original_dependency_check = s.check_public_source, s.check_dependencies
    for row in rows:
        run = row['run_id']; print(f"Validating {row['formula']} ({run})", flush=True)
        work = args.output / run; work.mkdir()
        inputs, promoted = work / 'input', work / 'promoted'
        observed = fetch(row, inputs)
        bundle = s.read_json(inputs / 'security-build.json')
        version = row['version']; source = bundle['release']['sources'][version]
        public_url = urls[version]
        if args.mode == 'rehearsal' and source.get('public_repository') == s.BACKPORTS_REPO:
            public_url = f'https://github.com/{s.BACKPORTS_REPO}/archive/refs/tags/php-{version}-security-rehearsal.tar.gz'
        s.require(public_url, f'Final public source URL is missing: {version}')
        override = work / 'public-source.json'
        s.write_json(override, {version: public_url} if source.get('public_repository') else {})
        if not source.get('public_repository'):
            s.require(public_url == source['public_url'], 'Official source URL cannot be overridden')
        source_results = []
        def check(v, src):
            s.require(src['sha256'] == catalog['sources'][v]['sha256'] and
                      src['public_url'] == public_url, 'Source verification binding mismatch')
            # Restore the original checker inside source_check to avoid recursively calling this closure.
            s.check_public_source = original_source_check
            try:
                source_results.append(verified_sources[v] if args.mode == 'public' else
                                      source_check(v, src, catalog, args.mode, args.output / 'sources'))
            finally:
                s.check_public_source = check
        s.check_public_source = check
        s.check_dependencies = lambda docs, deps=None: original_dependency_check(
            docs, deps, allow_newer_certificates=True)
        try:
            s.promote(SimpleNamespace(input=inputs, output=promoted, tap=args.tap, run_id=run,
                                      build_commit=row['commit'], public_sources=override))
        finally:
            s.check_public_source, s.check_dependencies = original_source_check, original_dependency_check
        # Use exactly Homebrew's normal package publication path; no bespoke OCI packaging.
        command('brew', 'ruby', '-e', 'require "sbom"; require "json_schemer"; schema = JSONSchemer.schema(SBOM.schema); ARGV.each { |p| abort "Invalid SBOM: #{p}" unless schema.validate(JSON.parse(File.read(p))).to_a.empty? }',
                '--', *sorted(promoted.glob('*.spdx.json')))
        command('brew', 'bottle', '--merge', '--write', '--no-commit', '--root-url=' + root_url,
                *sorted(promoted.glob('*.bottle.json')), cwd=promoted)
        command('brew', 'style', tap_name + '/' + row['formula'])
        command('brew', 'audit', '--skip-style', tap_name + '/' + row['formula'])
        command('brew', 'pr-upload', '--dry-run', '--no-commit', '--root-url=' + root_url, cwd=promoted)
        report = s.read_json(promoted / 'promotion.json')
        report['formula'] = row['formula']
        documents = [s.read_json(p) for p in sorted(promoted.glob('*.bottle.json'))]
        report['oci_layout'] = verify_security_packages.verify_layout(repo, tap_name, report, documents, promoted)
        for b in report['bottles']:
            b['payload_inventory_sha256'] = s.digest(json.dumps(b.pop('payload_sha256'), sort_keys=True).encode())
        report.update(formula=row['formula'], version=version, revision=row['revision'],
                      runtime_tests={p['tag']: p['runtime_test'] for p in row['platforms']},
                      live_release=observed, sources_verified=source_results,
                      destination=repo, mode=args.mode, completed_at=now(),
                      dependency_policy='All compiled versions exact; newer ca-certificates data allowed',
                      homebrew_merge_style_audit_sbom_upload_dry_run='passed')
        s.write_json(work / 'validation.json', report)
        shutil.copy(args.tap / 'Formula' / (row['formula'] + '.rb'), work / (row['formula'] + '.rb'))
        results.append(report)
        shutil.rmtree(inputs)
        if args.mode == 'rehearsal':
            for file in promoted.glob('*.tar.gz'):file.unlink()
    summary = {'schema': 1, 'catalog_sha256': s.file_digest(args.catalog), 'mode': args.mode,
               'destination': repo, 'baseline_commit': base, 'completed_at': now(),
               'releases': results, 'release_count': len(results), 'bottle_count': len(results) * 5,
               'asset_count': len(results) * 12,
               'runtime_tests': dict(Counter(v for r in results for v in r['runtime_tests'].values()))}
    s.write_json(args.output / 'validation.json', summary)
    if args.publish:
        # No upload begins until the entire requested selection passes all gates.
        s.require(s.git(args.tap, 'ls-remote', 'origin', 'refs/heads/' + args.branch).split()[0] == base,
                  'Destination branch moved; refuse publication')
        combined = args.output / 'upload'
        combined.mkdir()
        for row in rows:
            promoted = args.output / row['run_id'] / 'promoted'
            for path in promoted.iterdir():
                if path.name.endswith(('.bottle.json', '.tar.gz', '.spdx.json')):
                    os.link(path, combined / path.name)
        # Homebrew checks every destination tag for collisions before its first upload.
        command('brew', 'pr-upload', '--root-url=' + root_url, cwd=combined)
        for row in rows:
            promoted = args.output / row['run_id'] / 'promoted'
            report = s.read_json(args.output / row['run_id'] / 'validation.json')
            documents = [s.read_json(p) for p in sorted(promoted.glob('*.bottle.json'))]
            report['published_package'] = verify_security_packages.verify(repo, tap_name, report, documents)
            s.write_json(args.output / row['run_id'] / 'validation.json', report)
            ledger = args.tap / '.github/security-promotions' / (row['run_id'] + '.json')
            ledger.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(args.output / row['run_id'] / 'validation.json', ledger)
        command('git', 'add', '--', 'Formula', '.github/security-promotions', cwd=args.tap)
        command('git', 'commit', '-m', 'Publish validated PHP security bottles [skip-build]', cwd=args.tap)
        command('git', 'bundle', 'create', args.output / 'publication.bundle', base + '..HEAD', cwd=args.tap)
        command('git', '-c', 'credential.helper=!gh auth git-credential', 'push', 'origin',
                'HEAD:refs/heads/' + args.branch, cwd=args.tap)


def aggregate(args):
    catalog = load_catalog(args.catalog)
    reports = [s.read_json(p) for p in args.input.glob('*/validation.json')]
    s.require(len(reports) == 12, 'Expected exactly 12 version validation reports')
    s.require(all(r['catalog_sha256'] == s.file_digest(args.catalog) and r['destination'] == TEST_REPO
                  and r['mode'] == 'rehearsal' for r in reports), 'Mixed catalog, destination or mode')
    rows = [r for group in reports for r in group['releases']]
    s.require(len(rows) == 48 and len({r['private_run_id'] for r in rows}) == 48 and
              {r['private_run_id'] for r in rows} == {r['run_id'] for r in catalog['releases']},
              'Missing, duplicate or unexpected release result')
    for r in rows:
        pin = next(p for p in catalog['releases'] if p['run_id'] == r['private_run_id'])
        s.require(r['private_commit'] == pin['commit'] and r['formula'] == pin['formula'] and
                  r['version'] == pin['version'] and r['revision'] == pin['revision'] and
                  r['oci_layout']['verified_bottles'] == 5 and len(r['bottles']) == 5 and
                  {b['tag'] for b in r['bottles']} == PLATFORMS and
                  r['runtime_tests'] == {p['tag']: p['runtime_test'] for p in pin['platforms']} and
                  r['homebrew_merge_style_audit_sbom_upload_dry_run'] == 'passed', 'Invalid release result')
        for b in r['bottles']:
            p = next(p for p in pin['platforms'] if p['tag'] == b['tag'])
            s.require(b['original_sha256'] == p['sha256'] and b['unchanged_payload_entries'] > 0,
                      'Payload verification missing')
    outcomes = dict(Counter(v for r in rows for v in r['runtime_tests'].values()))
    s.require(outcomes == catalog['expected']['runtime_tests'], 'Runtime outcomes changed')
    args.output.mkdir(parents=True, exist_ok=False)
    s.write_json(args.output / 'all-48-validation.json', {
        'verified_at': now(), 'catalog_sha256': s.file_digest(args.catalog), 'releases': rows,
        'release_count': 48, 'bottle_count': 240, 'asset_count': 576, 'runtime_tests': outcomes,
        'public_source_availability_verified': False, 'packages_uploaded': False,
        'production_repository_modified': False})
    print('Verified all 48 releases / 240 bottles / 576 assets; runtime: 234 passed, 6 accepted interruptions.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('prepare', 'aggregate'))
    parser.add_argument('--catalog', type=Path, default=HERE / 'security-publication/catalog.json')
    parser.add_argument('--public-sources', type=Path, default=HERE / 'security-publication/public-sources.json')
    parser.add_argument('--mode', choices=('rehearsal', 'public'), default='rehearsal')
    parser.add_argument('--tap', type=Path, default=Path.cwd())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--versions', default='')
    parser.add_argument('--runs', default='')
    parser.add_argument('--branch', default='main')
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    args.tap = args.tap.resolve(); args.output = args.output.resolve()
    globals()[args.command](args)


if __name__ == '__main__':
    main()
