import tempfile
from pathlib import Path
import unittest

from test_security_bottles import NAME, VERSION, RECIPE, make_archive, s


class IsolatedPostinstallTests(unittest.TestCase):
    def setUp(self):
        self.original = RECIPE.replace('  def install\n', s.PHP_POSTINSTALL + '\n  def install\n')
        self.final = s.isolate_php_postinstall(self.original)

    def test_only_setup_changes_and_historical_recipe_is_exact(self):
        self.assertEqual(s.historical_postinstall_recipe(self.final), self.original)
        self.assertEqual(self.final.count('configure_php'), 1)
        self.assertIn('exec $PHP -n -C -q ', self.final)
        self.assertTrue(self.final.index('inreplace "pear"') < self.final.index('configure_php'))
        self.assertTrue(self.final.rindex('inreplace "pear"') > self.final.index('configure_php'))

    def test_repeated_generation_is_idempotent(self):
        self.assertEqual(s.isolate_php_postinstall(self.final), self.final)

    def test_embedded_patch_bytes_are_not_rewritten(self):
        patch = '\n__END__\n' + s.PHP_POSTINSTALL + '\n\n\n context\n'
        result = s.isolate_php_postinstall(self.original + patch)
        self.assertTrue(result.endswith(patch))
        self.assertEqual(s.historical_postinstall_recipe(result), self.original + patch)

    def test_unknown_or_multiple_setup_blocks_are_rejected(self):
        for recipe in (self.original.replace('    configure_php\n', '    run "something-else"\n'),
                       self.original + s.PHP_POSTINSTALL):
            with self.assertRaisesRegex(ValueError, 'Unknown PHP post-install'):
                s.isolate_php_postinstall(recipe)

    def test_expanded_variant_setup_keeps_every_original_step(self):
        body = ('    mkdir_p "lib/php/pecl", base: :homebrew_prefix\n'
                '    run "pear", base: :bin, args: ["update-channels"]\n'
                '    run "php", base: :bin, args: ["-n", "-v"]\n')
        original = self.original.replace('    configure_php\n', body)
        result = s.isolate_php_postinstall(original)
        self.assertEqual(s.historical_postinstall_recipe(result), original)
        self.assertIn(s.PHP_SETUP_GUARD + body + s.PHP_SETUP_RESTORE, result)
        self.assertEqual(s.isolate_php_postinstall(result), result)

    def test_modified_guard_is_not_waived_from_build_provenance(self):
        tampered = self.final.replace('exec $PHP -n -C -q ', 'exec arbitrary-command ', 1)
        self.assertNotEqual(s.recipe_fingerprint(s.historical_postinstall_recipe(tampered)),
                            s.recipe_fingerprint(self.original))

    def test_repack_preserves_launcher_and_compiled_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original, output = root / 'original.tar.gz', root / 'final.tar.gz'
            make_archive(original, self.original, {'bin/pear': b'#!/bin/sh\nexec $PHP -C -q "$@"\n'})
            s.repack(original, output, NAME, VERSION, self.final, [], [])
            before, after = s.inventory(original), s.inventory(output)
            for path in ('bin/pear', 'bin/php'):
                member = f'{NAME}/{VERSION}/{path}'
                self.assertEqual(before[member], after[member])

    def test_missing_or_changed_launcher_is_rejected(self):
        for contents in (None, b'#!/bin/sh\nexec something-else\n'):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                extra = {} if contents is None else {'bin/pear': contents}
                make_archive(root / 'original.tar.gz', self.original, extra)
                with self.assertRaisesRegex(ValueError, 'PEAR launcher'):
                    s.repack(root / 'original.tar.gz', root / 'final.tar.gz', NAME, VERSION,
                             self.final, [], [])


if __name__ == '__main__':
    unittest.main()
