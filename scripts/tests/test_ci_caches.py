import importlib.util
from pathlib import Path
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


summary = load('summary', 'ci-build-summary.py')
prune = load('prune', 'ci-prune-caches.py')
SHA_A = 'a' * 40
SHA_B = 'b' * 40


class BuildSummaryTests(unittest.TestCase):
    def test_counts_compiler_reuse_and_reads_timing_summary(self):
        log = [
            'Cache hit\n', 'note: replay cache hit\n', 'Cache hit\n', 'Cache miss\n',
            'Build Timing Summary\n', '\n',
            'SwiftCompile (26 tasks) | 311.258 seconds\n', '\n',
            'Ld (1 task) | 1.393 seconds\n',
            '** BUILD SUCCEEDED **\n',
            'Cache hit\n',
        ]
        hits, misses, timings = summary.parse(log)
        self.assertEqual((hits, misses), (3, 1))
        self.assertEqual(timings, [('SwiftCompile', 26, 311.258), ('Ld', 1, 1.393)])

    def test_a_later_summary_replaces_an_earlier_one(self):
        log = ['Build Timing Summary\n', 'Ld (1 task) | 1.0 seconds\n', '** BUILD SUCCEEDED **\n',
               'Build Timing Summary\n', 'CompileC (2 tasks) | 2.0 seconds\n']
        self.assertEqual(summary.parse(log)[2], [('CompileC', 2, 2.0)])

    def test_render_reports_state_without_claiming_success(self):
        text = summary.render('app-tests', 75, 65, 'restored', 3, 1, [('SwiftCompile', 26, 311.2)], 512)
        self.assertIn('### app-tests: 1m 15s (exit 65)', text)
        self.assertIn('Compilation cache: restored, 512 MB; 3 hits, 1 misses.', text)
        self.assertIn('| SwiftCompile | 26 | 311.2 |', text)
        self.assertIn('Compilation cache: not used.', summary.render('packages', 5, 0, '', 0, 0, [], None))


class PruneTests(unittest.TestCase):
    def entry(self, cache_id, key, created):
        return {'id': cache_id, 'key': key, 'createdAt': created}

    def test_keeps_newest_per_namespace_only(self):
        entries = [
            self.entry(1, f'xcode-cas-v1-x-app-tests-h1-{SHA_A}', '2026-09-24T01:00:00Z'),
            self.entry(2, f'xcode-cas-v1-x-app-tests-h1-{SHA_B}', '2026-09-25T01:00:00Z'),
            self.entry(3, f'xcode-cas-v1-x-release-build-h1-{SHA_A}', '2026-09-24T01:00:00Z'),
        ]
        self.assertEqual(prune.superseded(entries, 'xcode-cas-v1-'), [1])

    def test_ignores_other_prefixes_and_malformed_keys(self):
        entries = [
            self.entry(1, f'swift-deps-v1-x-{SHA_A}', '2026-09-24T01:00:00Z'),
            self.entry(2, 'xcode-cas-v1-x-app-tests-h1-notacommit', '2026-09-24T01:00:00Z'),
            self.entry(3, f'xcode-cas-v1-x-app-tests-h1-{SHA_A}', '2026-09-24T01:00:00Z'),
        ]
        self.assertEqual(prune.superseded(entries, 'xcode-cas-v1-'), [])

    def test_equal_timestamps_keep_one_deterministically(self):
        entries = [
            self.entry(7, f'xcode-cas-v1-ns-{SHA_A}', '2026-09-24T01:00:00Z'),
            self.entry(9, f'xcode-cas-v1-ns-{SHA_B}', '2026-09-24T01:00:00Z'),
        ]
        self.assertEqual(prune.superseded(entries, 'xcode-cas-v1-'), [7])


if __name__ == '__main__':
    unittest.main()
