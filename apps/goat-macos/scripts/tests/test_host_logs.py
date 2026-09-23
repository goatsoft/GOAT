import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('host_logs', Path(__file__).parents[1] / 'run-host-tests.py')
logs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logs)

BENIGN = ('2026-09-24 01:06:16.728270+0930 GOAT[32283:400579] '
          '[default] WebContent[32388] Conn 0x0 is not a valid connection ID.\n')


class HostLogTests(unittest.TestCase):
    def test_only_exact_framework_envelope_and_message_are_summarized(self):
        self.assertEqual(logs.benign_webkit_category(BENIGN), 'empty connection')
        for line in (f'error: assertion failed: {BENIGN}', 'Test Case failed: ' + BENIGN,
                     BENIGN.rstrip() + ' unexpected suffix',
                     BENIGN.replace('Conn 0x0 is not a valid connection ID.', 'WebProcess crashed'),
                     BENIGN.replace('GOAT[', 'SomeOtherApp[')):
            with self.subTest(line=line):
                self.assertIsNone(logs.benign_webkit_category(line))

    def test_retired_services_and_specific_preferences_denial(self):
        envelope = '2026-09-24 01:06:16.728270+0930 GOAT[32283:400579] '
        service = 'Could not signal service com.apple.WebKit.Networking: 113: Could not find specified service'
        preferences = ('WebContent[32388] networkd_settings_read_from_file_locked Sandbox is preventing '
                       'this process from reading networkd settings file at '
                       '"/Library/Preferences/com.apple.networkd.plist", please add an exception.')
        self.assertEqual(logs.benign_webkit_category(envelope + service), 'retired service')
        self.assertEqual(logs.benign_webkit_category(envelope + preferences), 'networkd preferences')
        self.assertIsNone(logs.benign_webkit_category(envelope + service.replace('113:', '1:')))
        self.assertIsNone(logs.benign_webkit_category(envelope + preferences.replace('networkd.plist', 'secret.plist')))

    def test_raw_log_and_failure_status_survive_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Tests.log'
            content = BENIGN + 'error: test assertion failed\n'
            command = [sys.executable, '-c',
                       'import sys; sys.stdout.write(sys.argv[1]); sys.exit(7)', content]
            for raw in (False, True):
                with self.subTest(raw=raw), contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(logs.run_logged(command, path, raw=raw), 7)
                self.assertEqual(path.read_text(), content)
                self.assertIn('error: test assertion failed', output.getvalue())
                self.assertEqual(BENIGN in output.getvalue(), raw)
                self.assertIn('empty connection=1', output.getvalue())
