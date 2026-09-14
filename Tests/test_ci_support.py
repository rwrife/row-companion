import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CISupportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('ci_support', ROOT / 'Scripts/ci_support.py')
        assert spec is not None and spec.loader is not None
        cls.support = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.support)

    def test_exact_xcode_pin_and_sdk_floor(self):
        self.support.validate_versions('Xcode 26.0\nBuild version 17A324', '26.0')
        self.support.validate_versions('Xcode 26.0\nBuild version 17A324', '26.1')
        for xcode, sdk in [('Xcode 26.1', '26.1'), ('Xcode 16.4', '26.0'),
                           ('Xcode 26.0', '18.5'), ('Xcode 26.0', ''),
                           ('Xcode 26.0 beta', '26.0')]:
            with self.subTest(xcode=xcode, sdk=sdk), self.assertRaises(ValueError):
                self.support.validate_versions(xcode, sdk)

    def test_selects_available_ios26_phone_by_udid(self):
        payload = {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [
                {'name': 'iPhone old', 'udid': '00000000-0000-0000-0000-000000000001', 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
                {'name': 'iPad Pro', 'udid': '00000000-0000-0000-0000-000000000002', 'isAvailable': True},
                {'name': 'iPhone 17', 'udid': '00000000-0000-0000-0000-000000000003', 'isAvailable': False},
                {'name': 'iPhone 17 Pro', 'udid': '00000000-0000-0000-0000-000000000004', 'isAvailable': True}]}}
        self.assertEqual(self.support.select_simulator(payload), '00000000-0000-0000-0000-000000000004')

    def test_selector_fails_closed_without_ios26(self):
        for payload in [{}, {'devices': {}}, {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
                {'name': 'iPhone', 'udid': 'unsafe; shell', 'isAvailable': True}]}}]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.support.select_simulator(payload)

    def test_summary_is_allowlisted_not_arbitrary_test_strings(self):
        summary = {'title': '/Users/private/pattern.pdf', 'totalTestCount': 2,
                   'passedTests': 2, 'failedTests': 0, 'skippedTests': 0,
                   'testFailures': [{'message': 'secret private pattern'}],
                   'result': 'Passed', 'finishTime': 123.0}
        clean = self.support.sanitize_summary(summary)
        self.assertEqual(clean, {'totalTestCount': 2, 'passedTests': 2,
                                'failedTests': 0, 'skippedTests': 0, 'result': 'Passed'})
        self.assertNotIn('private', json.dumps(clean))

    def test_summary_rejects_contradictory_results(self):
        for result, passed, failed, skipped in [('Failed', 2, 0, 0),
                                               ('Skipped', 1, 0, 1),
                                               ('Skipped', 0, 1, 1)]:
            with self.subTest(result=result), self.assertRaises(ValueError):
                self.support.sanitize_summary({'totalTestCount': 2, 'passedTests': passed,
                                               'failedTests': failed, 'skippedTests': skipped,
                                               'result': result})
        for result, passed, failed, skipped in [('Passed', 2, 0, 0),
                                               ('Failed', 1, 1, 0),
                                               ('Skipped', 0, 0, 2)]:
            value = {'totalTestCount': 2, 'passedTests': passed, 'failedTests': failed,
                     'skippedTests': skipped, 'result': result}
            self.assertEqual(self.support.sanitize_summary(value), value)

    def test_summary_requires_real_counts(self):
        for payload in [{}, {'totalTestCount': True}, {'totalTestCount': -1},
                        {'totalTestCount': 0, 'passedTests': 0, 'failedTests': 0, 'skippedTests': 0, 'result': 'Passed'}]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.support.sanitize_summary(payload)


if __name__ == '__main__':
    unittest.main()
