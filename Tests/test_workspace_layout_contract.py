from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'
WORKSPACE = APP / 'Features' / 'Workspace'


class WorkspaceLayoutContractTests(unittest.TestCase):
    """Static source-contract checks for issue #4 (accessible workspace).
    These are NOT iOS build or simulator evidence — real acceptance runs in
    the pinned macOS CI job."""

    def test_arrangement_rules_are_pure_and_wired(self):
        text = (WORKSPACE / 'WorkspaceArrangement.swift').read_text()
        # Pure rules: no UI/persistence imports in the arrangement seam.
        self.assertNotIn('import SwiftUI', text)
        self.assertNotIn('import SwiftData', text)
        # Exact two-pane rule from PLAN.md/README: regular width AND
        # non-accessibility Dynamic Type; accessibility sizes stack.
        self.assertIn('regularWidth && !isAccessibilitySize', text)
        # Pane order is reversible and arrangement-only.
        self.assertIn('case referenceFirst', text)
        self.assertIn('case controlsFirst', text)
        self.assertIn('func flipped', text)
        # The dual-screen future seam is a note, never a fold SDK import.
        self.assertIn('DualScreenAdapterNote', text)
        layout = (WORKSPACE / 'WorkspaceLayout.swift').read_text()
        self.assertIn('WorkspaceArrangement.useTwoPane', layout)
        self.assertIn('WorkspaceArrangement.flipped', layout)
        self.assertIn('control.paneOrder', layout)

    def test_guide_control_is_non_gesture_and_identifier_stable(self):
        layout = (WORKSPACE / 'WorkspaceLayout.swift').read_text()
        # The reading guide has an explicit accessibility-identifiable
        # slider + off button (VoiceOver / Switch Control routes, no
        # mandatory drag gesture on the PDF itself).
        self.assertIn('control.guideSlider', layout)
        self.assertIn('control.guideOff', layout)
        self.assertIn('model.setGuide', layout)

    def test_completed_and_next_rows_are_separate_accessibility_targets(self):
        layout = (WORKSPACE / 'WorkspaceLayout.swift').read_text()
        # Separate labelled identifiers so VoiceOver focus and automation
        # address completed vs next rows independently (no merged container).
        self.assertIn('row.completed', layout)
        self.assertIn('row.next', layout)
        arithmetic = (APP / 'Domain' / 'RowArithmetic.swift').read_text()
        self.assertIn('Completed rows', arithmetic)
        self.assertIn('Next repeat row', arithmetic)

    def test_counter_targets_meet_44_point_minimum(self):
        layout = (WORKSPACE / 'WorkspaceLayout.swift').read_text()
        # Every actionable counter/control label enforces the 44pt floor.
        self.assertGreaterEqual(layout.count('minHeight: 44'), 3)

    def test_layout_files_have_no_row_action_construction(self):
        # Arrangement code (layout + pure rules) must never construct row
        # actions; only WorkspaceModel mutation entrypoints may reference them.
        for name in ('WorkspaceLayout.swift', 'WorkspaceArrangement.swift'):
            text = (WORKSPACE / name).read_text()
            self.assertNotIn('RowAction(', text, name)
            self.assertNotIn('RowAction.', text, name)

    def test_new_sources_wired_into_project_targets(self):
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        self.assertIn('path = WorkspaceArrangement.swift', project)
        self.assertIn('path = WorkspaceArrangementTests.swift', project)

    def test_two_pane_ui_journey_exists(self):
        smoke = (ROOT / 'RowCompanionUITests' / 'RowCompanionUITests.swift').read_text()
        self.assertIn('-rc-force-two-pane', smoke)
        self.assertIn('control.paneOrder', smoke)
        self.assertIn('testTwoPaneReorderPreservesStateAndEmitsNoRowEvent', smoke)


if __name__ == '__main__':
    unittest.main()
