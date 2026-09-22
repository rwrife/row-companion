from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'


class DocumentImportContractTests(unittest.TestCase):
    """Static source-contract checks for issue #3 (PDF import + resume).
    These are NOT iOS build or simulator evidence — real acceptance runs in
    the pinned macOS CI job."""

    def test_new_sources_exist_and_are_wired_into_project(self):
        names = sorted(p.name for p in APP.rglob('*.swift'))
        for expected in ('ReferenceState.swift', 'DocumentModels.swift', 'PDFCoordinateSpace.swift',
                         'DocumentRecords.swift', 'PDFImport.swift',
                         'WorkspaceModel.swift', 'WorkspaceLayout.swift', 'RowPDFView.swift'):
            self.assertIn(expected, names)
        test_names = sorted(p.name for p in (ROOT / 'RowCompanionTests').glob('*.swift'))
        for expected in ('ViewportClampTests.swift', 'PDFImportTests.swift', 'ReferenceStateTests.swift'):
            self.assertIn(expected, test_names)
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        for source in names + test_names:
            self.assertIn('path = ' + source, project)

    def test_domain_stays_ui_and_pdf_free(self):
        for path in (APP / 'Domain').glob('*.swift'):
            text = path.read_text()
            self.assertNotIn('import SwiftUI', text, path.name)
            self.assertNotIn('import SwiftData', text, path.name)
            self.assertNotIn('import PDFKit', text, path.name)

    def test_import_bounds_match_plan(self):
        text = (APP / 'Documents' / 'PDFImport.swift').read_text()
        self.assertIn('maximumBytes = 50 * 1024 * 1024', text)
        self.assertIn('maximumPages = 500', text)
        # Security-scoped access must be balanced.
        self.assertIn('startAccessingSecurityScopedResource', text)
        self.assertIn('stopAccessingSecurityScopedResource', text)
        self.assertIn('defer', text)
        # Locked documents fail closed with an actionable message.
        self.assertIn('/Encrypt', text)

    def test_reference_state_pins_clamping_and_coordinate_convention(self):
        domain = (APP / 'Domain' / 'ReferenceState.swift').read_text()
        self.assertIn('top-left origin', domain)
        self.assertIn('func clamp(', domain)
        coords = (APP / 'Domain' / 'PDFCoordinateSpace.swift').read_text()
        self.assertIn('1 - rect.y - rect.height', coords)

    def test_guide_and_selection_have_no_row_action_path(self):
        # The viewer wrapper and guide overlay never construct row actions;
        # only explicit control buttons do (enforced structurally: RowAction
        # appears in exactly the control surface and the repository/model
        # mutation entrypoints, not in view geometry code).
        for path in (APP / 'Features' / 'Workspace').glob('*.swift'):
            if path.name == 'WorkspaceModel.swift':
                continue
            text = path.read_text()
            self.assertNotIn('RowAction(', text, path.name)
            self.assertNotIn('RowAction.', text, path.name)

    def test_viewer_disables_link_and_selection_surface(self):
        text = (APP / 'Features' / 'Workspace' / 'RowPDFView.swift').read_text()
        self.assertIn('isSelectionEnabled = false', text)
        # No link/URL handling is ever installed by this wrapper.
        self.assertNotIn('URL.open', text)
        self.assertNotIn('openURL', text)
        self.assertIn('never installs link/URL handling', ' '.join(text.split()))

    def test_ui_test_journey_targets_workspace_controls(self):
        smoke = (ROOT / 'RowCompanionUITests' / 'RowCompanionUITests.swift').read_text()
        for identifier in ('control.completeRow', 'control.undo', 'row.completed',
                           'workspace.title', 'workspace.status'):
            self.assertIn(identifier, smoke)
        app_text = (ROOT / 'RowCompanion' / 'ContentView.swift').read_text()
        layout_text = (ROOT / 'RowCompanion' / 'Features' / 'Workspace' / 'WorkspaceLayout.swift').read_text()
        for identifier in ('control.completeRow', 'control.undo'):
            self.assertIn(identifier, layout_text)
        self.assertIn('workspace.title', app_text)
        self.assertIn('workspace.status', app_text)


if __name__ == '__main__':
    unittest.main()
