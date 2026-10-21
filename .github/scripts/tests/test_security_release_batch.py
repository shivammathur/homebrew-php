import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1]))
import security_release_batch as batch
import security_bottles as s

CATALOG = batch.HERE / 'security-publication/catalog.json'


class ReleaseBatchGuards(unittest.TestCase):
    def test_complete_catalog(self):
        c = batch.load_catalog(CATALOG)
        self.assertEqual(sum(len(r['assets']) for r in c['releases']), 576)
        self.assertEqual(len(batch.select(c, '', '')), 48)
        self.assertEqual(len(batch.select(c, '5.6.40', '')), 4)

    def reject_catalog(self, change, message):
        c = s.read_json(CATALOG)
        change(c)
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'catalog.json';s.write_json(path, c)
            with self.assertRaisesRegex(ValueError, message):batch.load_catalog(path)

    def test_missing_release(self):
        self.reject_catalog(lambda c: c['releases'].pop(), 'exactly 48')

    def test_duplicate_platform(self):
        self.reject_catalog(lambda c: c['releases'][0]['platforms'].__setitem__(0, c['releases'][0]['platforms'][1]), 'platform matrix')

    def test_interruption_approval_bound_to_hash(self):
        def mutate(c):
            p = next(p for r in c['releases'] for p in r['platforms'] if p['runtime_test'] == 'interrupted')
            p['accepted_interruption']['sha256'] = '0' * 64
        self.reject_catalog(mutate, 'interruption approval')

    def test_interruption_cannot_be_passed(self):
        def mutate(c):
            p = next(p for r in c['releases'] for p in r['platforms'] if p['runtime_test'] == 'interrupted')
            p['runtime_test'] = 'passed'
        self.reject_catalog(mutate, 'Unapproved runtime outcome')

    def test_wrapper_failure_requires_bound_proof(self):
        def mutate(c):
            p = next(p for r in c['releases'] for p in r['platforms'] if 'post_test_failure' in p)
            p['post_test_failure']['commit'] = '0' * 40
        self.reject_catalog(mutate, 'post-test failure proof')

    def test_unknown_or_duplicate_selection(self):
        c = batch.load_catalog(CATALOG)
        for versions, runs in [('5.6.40,5.6.40', ''), ('9.0.0', ''), ('', '39327425934'), ('5.6.40', '39363696274')]:
            with self.assertRaises(ValueError):batch.select(c, versions, runs)

    def test_no_cross_repository_destination(self):
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': batch.TEST_REPO}), \
             patch.object(s, 'git', return_value='https://github.com/' + batch.PRODUCTION_REPO):
            with self.assertRaisesRegex(ValueError, 'origin mismatch'):batch.destination(Path('.'), 'public')

    def test_no_rehearsal_in_production(self):
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': batch.PRODUCTION_REPO}):
            with self.assertRaisesRegex(ValueError, 'restricted'):batch.destination(Path('.'), 'rehearsal')

    def test_private_test_visibility_required(self):
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': batch.TEST_REPO}), \
             patch.object(s, 'git', return_value='https://github.com/' + batch.TEST_REPO), \
             patch.object(batch, 'api', return_value={'full_name': batch.TEST_REPO, 'private': False}):
            with self.assertRaisesRegex(ValueError, 'visibility changed'):batch.destination(Path('.'), 'rehearsal')

    def test_public_sources_never_fall_back_to_fixtures(self):
        c = batch.load_catalog(CATALOG);v = '8.2.35'
        source = {'sha256': c['sources'][v]['sha256'], 'public_url': c['sources'][v]['public_url']}
        with patch.object(s, 'check_public_source', side_effect=ValueError('public bytes differ')), \
             patch.object(batch.subprocess, 'run') as call:
            with self.assertRaisesRegex(ValueError, 'public bytes differ'):
                batch.source_check(v, source, c, 'public', Path('/unused'))
            call.assert_not_called()

    def test_fixture_tampering_rejected(self):
        c = batch.load_catalog(CATALOG);v = '8.2.35'
        source = {'sha256': c['sources'][v]['sha256'], 'public_url': c['sources'][v]['public_url']}
        with tempfile.TemporaryDirectory() as temp:
            cache=Path(temp);(cache/c['sources'][v]['fixture_name']).write_bytes(b'wrong')
            with self.assertRaisesRegex(ValueError, 'differs from built source'):
                batch.source_check(v, source, c, 'rehearsal', cache)

    def test_incomplete_aggregate_rejected(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'exactly 12'):
                batch.aggregate(SimpleNamespace(catalog=CATALOG, input=Path(temp), output=Path(temp)/'out'))


class PackagePublicationGuards(unittest.TestCase):
    def test_homebrew_rebuild_tags(self):
        from verify_security_packages import image_tag, platform_tag
        self.assertEqual(image_tag('7.3.33_17', 1), '7.3.33_17-1')
        self.assertEqual(image_tag('8.2.35', 0), '8.2.35')
        self.assertEqual(platform_tag('7.3.33_17.arm64_linux.1', '7.3.33_17', 1), 'arm64_linux')
        with self.assertRaisesRegex(ValueError, 'rebuild mismatch'):
            platform_tag('7.3.33_17.arm64_linux.2', '7.3.33_17', 1)

    def test_production_template_only_changes_repository_guard(self):
        root = batch.HERE
        active = (root / 'workflows/publish-security-release-batch.yml').read_text()
        template = (root / 'workflow-templates/publish-security-release-batch.yml').read_text()
        self.assertEqual(template, active.replace("github.repository == 'shivammathur/homebrew-php-security-test'",
                                                "github.repository == 'shivammathur/homebrew-php'"))


class OciReceiptValidation(unittest.TestCase):
    def test_only_linux_lts_label_is_normalized(self):
        from verify_security_packages import expected_oci_tab
        original = {'built_on': {'os': 'Linux', 'os_version': 'Ubuntu 24.04.5 LTS', 'glibc_version': '2.39'},
                    'runtime_dependencies': [{'full_name': 'openssl@4', 'pkg_version': '4.0.3'}]}
        expected = copy.deepcopy(original);expected['built_on']['os_version'] = 'Ubuntu 24.04.5'
        self.assertEqual(expected_oci_tab(original), expected)
        self.assertEqual(original['built_on']['os_version'], 'Ubuntu 24.04.5 LTS')
        altered = copy.deepcopy(original);altered['runtime_dependencies'][0]['pkg_version'] = '4.0.2'
        self.assertNotEqual(expected_oci_tab(altered), expected)
