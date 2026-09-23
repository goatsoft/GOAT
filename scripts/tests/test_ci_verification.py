import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('verification', Path(__file__).parents[1] / 'ci-verification.py')
verification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verification)


class VerificationTests(unittest.TestCase):
    def needs(self, app='true', changes='success', lint='success', phase='success'):
        return {'changes': {'result': changes, 'outputs': {'app': app}},
                'lint': {'result': lint}, 'verification': {'result': phase}}

    def test_complete_and_explicit_content_only_runs(self):
        self.assertTrue(verification.verified(self.needs()))
        self.assertTrue(verification.verified(self.needs(app='', lint='success')))
        self.assertTrue(verification.verified(self.needs(app='false', lint='skipped', phase='skipped')))

    def test_failed_cancelled_missing_and_unexpected_skips_fail_closed(self):
        self.assertFalse(verification.verified({}))
        for result in ('failure', 'cancelled', 'skipped', ''):
            for job in ('changes', 'lint', 'phase'):
                with self.subTest(result=result, job=job):
                    self.assertFalse(verification.verified(self.needs(**{job: result})))
        self.assertFalse(verification.verified(self.needs(app='false', changes='failure', lint='skipped', phase='skipped')))
        self.assertFalse(verification.verified(self.needs(app='false', lint='failure', phase='skipped')))
