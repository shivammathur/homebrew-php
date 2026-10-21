"""Read back Homebrew's OCI index and every uploaded layer before advancing the tap."""
import base64
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import subprocess
import urllib.parse
import urllib.request

import security_bottles as s


class NoRedirectCredentials(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new and urllib.parse.urlsplit(req.full_url).hostname != urllib.parse.urlsplit(newurl).hostname:
            new.remove_header('Authorization')
        return new


def image_tag(version, rebuild):
    return version + ('-' + str(rebuild) if rebuild else '')


def platform_tag(ref, version, rebuild):
    s.require(ref.startswith(version + '.'), 'Published bottle version mismatch')
    tag = ref[len(version) + 1:]
    if rebuild:
        suffix = '.' + str(rebuild)
        s.require(tag.endswith(suffix), 'Published bottle rebuild mismatch')
        tag = tag[:-len(suffix)]
    return tag


def verify(repo, tap, report, documents):
    owner, tap_short = tap.split('/')
    package_name = tap_short + '/' + report['formula'].replace('@', '/').replace('+', 'x')
    package = json.loads(subprocess.check_output(['gh', 'api',
        f'users/{owner}/packages/container/' + urllib.parse.quote(package_name, safe='')], text=True))
    s.require(package['repository']['full_name'] == repo and
              package['visibility'] == ('private' if repo.endswith('-security-test') else 'public'),
              'Published package visibility or repository mismatch')
    name = report['formula']; expected = {b['tag']: b for b in report['bottles']}
    entry = documents[0][tap + '/' + name]
    version = entry['formula']['pkg_version']; rebuild = entry['bottle'].get('rebuild', 0)
    image_version = image_tag(version, rebuild)
    image = tap + '/' + name.replace('@', '/').replace('+', 'x')
    opener = urllib.request.build_opener(NoRedirectCredentials())
    credential = base64.b64encode((os.environ['HOMEBREW_GITHUB_PACKAGES_USER'] + ':' +
                                  os.environ['HOMEBREW_GITHUB_PACKAGES_TOKEN']).encode()).decode()
    token_url = 'https://ghcr.io/token?' + urllib.parse.urlencode({
        'service': 'ghcr.io', 'scope': 'repository:' + image + ':pull'})
    with opener.open(urllib.request.Request(token_url, headers={'Authorization': 'Basic ' + credential}), timeout=60) as r:
        token = json.load(r)['token']

    def get(path):
        return opener.open(urllib.request.Request('https://ghcr.io/v2/' + image + '/' + path, headers={
            'Authorization': 'Bearer ' + token,
            'Accept': 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json'}), timeout=180)

    with get('manifests/' + image_version) as r:index_bytes = r.read()
    index = json.loads(index_bytes)
    s.require(len(index['manifests']) == 5 and
              index['annotations']['org.opencontainers.image.source'].startswith('https://github.com/' + repo + '/'),
              'Published index matrix or repository mismatch')

    def bottle(descriptor):
        ref = descriptor['annotations']['org.opencontainers.image.ref.name']
        tag = platform_tag(ref, version, rebuild)
        s.require(tag in expected, 'Unexpected published bottle tag')
        with get('manifests/' + descriptor['digest']) as r:raw = r.read()
        s.require('sha256:' + s.digest(raw) == descriptor['digest'], 'Published manifest digest mismatch')
        manifest = json.loads(raw)
        s.require(len(manifest['layers']) == 1, 'Unexpected published layer count')
        layer = manifest['layers'][0]
        s.require(layer['digest'] == 'sha256:' + expected[tag]['published_sha256'], 'Published bottle checksum mismatch')
        digest = hashlib.sha256();size = 0
        with get('blobs/' + layer['digest']) as response:
            while chunk := response.read(1024 * 1024):digest.update(chunk);size += len(chunk)
        s.require(digest.hexdigest() == expected[tag]['published_sha256'] and size == layer['size'],
                  'Downloaded published bottle differs from verified candidate')
        return {'tag': tag, 'sha256': digest.hexdigest(), 'size': size}

    with ThreadPoolExecutor(max_workers=3) as pool:results = list(pool.map(bottle, index['manifests']))
    s.require({b['tag'] for b in results} == set(expected), 'Incomplete published platform set')
    return {'image': 'ghcr.io/' + image + ':' + image_version, 'index_sha256': s.digest(index_bytes),
            'bottles': results, 'download_verified': True}


def expected_oci_tab(tab):
    result = copy.deepcopy(tab)
    built_on = result.get('built_on', {})
    # Homebrew GitHubPackages#upload_bottle removes this exact suffix in place.
    if built_on.get('os') == 'Linux' and isinstance(built_on.get('os_version'), str):
        built_on['os_version'] = built_on['os_version'].removesuffix(' LTS')
    return result


def verify_layout(repo, tap, report, documents, directory):
    """Independently verify the actual OCI files produced by Homebrew's dry run."""
    name = report['formula']; expected = {b['tag']: b for b in report['bottles']}
    entries = [d[tap + '/' + name] for d in documents]
    version = entries[0]['formula']['pkg_version'];rebuild = entries[0]['bottle'].get('rebuild', 0)
    root = directory / (name + '--' + image_tag(version, rebuild))
    layout = s.read_json(root / 'oci-layout')
    s.require(layout['imageLayoutVersion'] == '1.0.0', 'Unsupported OCI layout')
    outer = s.read_json(root / 'index.json')
    s.require(len(outer['manifests']) == 1, 'Expected a single OCI image index')
    def blob(descriptor):
        sha = descriptor['digest'].removeprefix('sha256:')
        s.require(s.SHA256.fullmatch(sha), 'Invalid OCI digest')
        path = root / 'blobs/sha256' / sha
        s.require(path.stat().st_size == descriptor['size'] and s.file_digest(path) == sha,
                  'OCI blob digest or size mismatch')
        return path
    index = s.read_json(blob(outer['manifests'][0]))
    s.require(len(index['manifests']) == 5 and
              index['annotations']['org.opencontainers.image.source'].startswith('https://github.com/' + repo + '/'),
              'OCI repository or matrix mismatch')
    tags = {tag: info for entry in entries for tag, info in entry['bottle']['tags'].items()}
    seen = set()
    for descriptor in index['manifests']:
        tag = platform_tag(descriptor['annotations']['org.opencontainers.image.ref.name'], version, rebuild)
        s.require(tag in expected and tag not in seen, 'Duplicate or unexpected OCI platform')
        seen.add(tag)
        s.require(json.loads(descriptor['annotations']['sh.brew.tab']) == expected_oci_tab(tags[tag]['tab']),
                  'OCI runtime receipt differs from promoted bottle metadata')
        manifest = s.read_json(blob(descriptor))
        blob(manifest['config'])
        s.require(len(manifest['layers']) == 1 and
                  manifest['layers'][0]['digest'] == 'sha256:' + expected[tag]['published_sha256'],
                  'OCI layer differs from verified promoted bottle')
        blob(manifest['layers'][0])
    s.require(seen == set(expected), 'Incomplete OCI matrix')
    return {'verified_bottles': len(seen), 'index_sha256': outer['manifests'][0]['digest'],
            'runtime_receipts': 'exact match after Homebrew Linux LTS label normalization', 'layers': 'full bytes checked against promoted checksums'}
