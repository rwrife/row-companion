from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class ProjectContractTests(unittest.TestCase):
    def test_project_identifiers_are_defined_and_scheme_targets_exist(self):
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        definitions = re.findall(r'^  ([A-F0-9]{24}) =', project, re.MULTILINE)
        self.assertEqual(len(definitions), len(set(definitions)))
        identifiers = set(re.findall(r'\b[A-F0-9]{24}\b', project))
        self.assertEqual(identifiers, set(definitions))
        scheme = ET.parse(ROOT / 'RowCompanion.xcodeproj/xcshareddata/xcschemes/RowCompanion.xcscheme')
        tests = scheme.findall('.//TestableReference')
        self.assertEqual(len(tests), 2)
        for test in tests:
            self.assertEqual(test.get('skipped'), 'NO')
        for reference in scheme.findall('.//BuildableReference'):
            self.assertIn(reference.get('BlueprintIdentifier'), identifiers)
        for source in ('RowCompanionApp.swift', 'ContentView.swift', 'RowCompanionTests.swift', 'RowCompanionUITests.swift'):
            self.assertIn('path = ' + source, project)
            self.assertEqual(len(list(ROOT.glob('*/' + source))), 1)
        self.assertIn('SWIFT_VERSION = 6.0', project)
        self.assertIn('IPHONEOS_DEPLOYMENT_TARGET = 26.0', project)
        self.assertNotIn('CloudKit', project)
        self.assertNotIn('XCRemoteSwiftPackageReference', project)

    def test_ci_wires_native_commands_and_does_not_upload_raw_bundles(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('/Applications/Xcode_26.0.app/Contents/Developer', workflow)
        self.assertIn('bash Scripts/ci_native.sh simulator-test', workflow)
        self.assertIn('bash Scripts/ci_native.sh device-build', workflow)
        self.assertIn('path: artifacts/evidence/', workflow)
        self.assertNotIn('path: artifacts/RowCompanion.xcresult', workflow)
        self.assertNotIn('secrets.', workflow)
        script = (ROOT / 'Scripts/ci_native.sh').read_text()
        self.assertIn('CODE_SIGNING_ALLOWED=NO test', script)
        self.assertIn("generic/platform=iOS", script)
        self.assertIn('CODE_SIGNING_ALLOWED=NO build', script)
        self.assertIn('platform=iOS Simulator,id=$UDID', script)

    def test_ci_records_exact_head_and_diagnoses_alias_before_pin_check(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertEqual(workflow.count('ref: ${{ github.event.pull_request.head.sha || github.sha }}'), 2)
        self.assertIn('git rev-parse HEAD', workflow)
        inventory = workflow.index('for developer in /Applications/Xcode*.app/Contents/Developer; do')
        gate = workflow.index('python3 Scripts/ci_support.py check-toolchain')
        self.assertLess(inventory, gate)
        self.assertIn('DEVELOPER_DIR="$developer" xcodebuild -version', workflow)
        self.assertNotIn('continue-on-error:', workflow)
        self.assertNotIn('sudo xcode-select', workflow)

    def test_launch_contract_matches_app_accessibility_identifiers(self):
        app = (ROOT / 'RowCompanion/ContentView.swift').read_text()
        smoke = (ROOT / 'RowCompanionUITests/RowCompanionUITests.swift').read_text()
        self.assertIn('app.launch()', smoke)
        self.assertIn('.runningForeground', smoke)
        for identifier in ('workspace.title', 'workspace.status'):
            self.assertIn(identifier, app)
            self.assertIn(identifier, smoke)


if __name__ == '__main__':
    unittest.main()
