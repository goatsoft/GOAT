import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('host_tests', Path(__file__).parents[1] / 'run-host-tests.py')
host_tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host_tests)


class TestSelectionTests(unittest.TestCase):
    def test_empty_and_entirely_skipped_runs_fail(self):
        for summary in ({}, {'passedTests': 0, 'failedTests': 0}, {'skippedTests': 3}):
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                host_tests.require_executed_tests(summary)

    def test_executed_tests_are_accepted_even_with_optional_skips(self):
        host_tests.require_executed_tests({'passedTests': 1, 'failedTests': 0, 'skippedTests': 2})

layout_spec = importlib.util.spec_from_file_location('test_layout', Path(__file__).parents[1] / 'check-test-layout.py')
layout = importlib.util.module_from_spec(layout_spec)
layout_spec.loader.exec_module(layout)


class TestPlanOwnershipTests(unittest.TestCase):
    def test_missing_native_class_and_legacy_swift_selector_are_rejected(self):
        import json
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ('App/Tests', 'TestPlans', 'GOAT.xcodeproj/xcshareddata/xcschemes'):
                shutil.copytree(layout.ROOT / relative, root / relative)
            self.assertEqual(layout.validate(root), [])
            plan = root / 'TestPlans/Paddock.xctestplan'
            data = json.loads(plan.read_text())
            data['testTargets'][0]['selectedTests']['xctestClasses'].pop()
            plan.write_text(json.dumps(data))
            self.assertTrue(any('Paddock: plan selection' in s for s in layout.validate(root)))
            plan = root / 'TestPlans/Bleet.xctestplan'
            data = json.loads(plan.read_text())
            data['testTargets'][0]['selectedTests'] = ['AppTests/Bleet']
            plan.write_text(json.dumps(data))
            self.assertTrue(any('Bleet: plan selection' in s for s in layout.validate(root)))
            plan = root / 'TestPlans/All.xctestplan'
            data = json.loads(plan.read_text())
            del data['defaultOptions']['targetForVariableExpansion']
            plan.write_text(json.dumps(data))
            self.assertTrue(any('expansion target' in s for s in layout.validate(root)))
