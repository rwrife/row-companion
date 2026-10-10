from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FocusContractTests(unittest.TestCase):
    """Host wiring checks only; native behavior is proved by Xcode UI tests."""

    def test_focus_has_independent_exit_and_explicit_power_opt_in(self):
        content = (ROOT / 'RowCompanion/ContentView.swift').read_text()
        self.assertIn('focus.enter', content)
        self.assertIn('focus.exit', content)
        self.assertIn('focus.keepAwake', content)
        self.assertIn('focus.haptics', content)
        self.assertIn('isIdleTimerDisabled =', content)
        self.assertIn('scenePhase == .active', content)
        self.assertIn('UIAccessibility.isReduceMotionEnabled', content)
        self.assertIn('model.completeRow()', content)
        self.assertIn('model.undoRow()', content)
        self.assertNotIn('RowAction.', content)

    def test_focus_native_journey_covers_reversible_count_and_failure(self):
        ui = (ROOT / 'RowCompanionUITests/RowCompanionUITests.swift').read_text()
        self.assertIn('testFocusedCountingKeepsProgressAndWorkspaceAcrossExit', ui)
        unit = (ROOT / 'RowCompanionTests/RowRepositoryTests.swift').read_text()
        self.assertIn('testFocusedCountReportsSaveOutcome', unit)


if __name__ == '__main__':
    unittest.main()
