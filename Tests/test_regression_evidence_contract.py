from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RegressionEvidenceContractTests(unittest.TestCase):
    """Host contracts for issue #6. These are not iOS/device evidence."""

    def test_end_to_end_and_dynamic_type_journeys_are_in_native_suite(self):
        ui = (ROOT / "RowCompanionUITests/RowCompanionUITests.swift").read_text()
        self.assertIn(
            "testEndToEndProgressContinuityAcrossPiecesLayoutAndRelaunch", ui
        )
        self.assertIn(
            "testAccessibilityDynamicTypeReflowsRegularWidthToStacked", ui
        )
        for required in (
            "control.completeRow",
            "control.undo",
            "control.repeatLength",
            "control.notes",
            "control.piece",
            "-rc-force-regular-width",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ):
            self.assertIn(required, ui)

    def test_no_application_network_or_cloud_sync_surface(self):
        source = "\n".join(
            path.read_text()
            for path in (ROOT / "RowCompanion").rglob("*.swift")
        )
        for forbidden in (
            "import Network",
            "import CloudKit",
            "URLSession",
            "CKContainer",
            "NSAllowsArbitraryLoads",
        ):
            self.assertNotIn(forbidden, source)

        project = (ROOT / "RowCompanion.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("com.apple.developer.icloud", project)
        self.assertNotIn("CloudKit", project)


if __name__ == "__main__":
    unittest.main()