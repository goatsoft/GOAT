import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('project_check', Path(__file__).parents[1] / 'check-xcode-project.py')
project_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(project_check)


class ProjectContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = project_check.load_project()

    def test_missing_and_duplicate_membership_are_rejected(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                target = next(x for x in objects.values() if x.get('name') == 'GOAT' and x['isa'] == 'PBXNativeTarget')
                phase = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == 'PBXSourcesBuildPhase')
                if duplicate:
                    phase['files'].append(phase['files'][0])
                else:
                    phase['files'].pop()
                self.assertTrue(any('source membership' in s for s in project_check.validate(project)))

    def test_stale_metadata_wiring_is_rejected(self):
        project = copy.deepcopy(self.project)
        for obj in project['objects'].values():
            if obj['isa'] == 'PBXShellScriptBuildPhase':
                obj.pop('alwaysOutOfDate', None)
            if obj['isa'] == 'XCBuildConfiguration' and 'INFOPLIST_FILE' in obj['buildSettings']:
                obj['buildSettings']['INFOPLIST_FILE'] = 'App/Info.plist'
        failures = project_check.validate(project)
        self.assertTrue(any('every build' in s for s in failures))
        self.assertTrue(any('generated Info.plist' in s for s in failures))
