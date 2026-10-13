from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'


class AnnotationContractTests(unittest.TestCase):
    """Static source-contract checks for issue #17. NOT iOS build or
    simulator evidence; real acceptance runs in the pinned macOS CI job."""

    def test_sources_exist_and_are_wired_into_project(self):
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        for name in ('DocumentAnnotations.swift', 'AnnotationRepository.swift', 'AnnotationTests.swift'):
            self.assertIn('path = ' + name, project)
            self.assertIn(name + ' in Sources', project)

    def test_annotations_never_rewrite_pdf_bytes(self):
        for rel in ('Persistence/AnnotationRepository.swift', 'Domain/DocumentAnnotations.swift'):
            text = (APP / rel).read_text()
            for forbidden in ('.write(', 'PDFDocument', 'dataRepresentation', 'documentFileBytes'):
                self.assertNotIn(forbidden, text, rel)
        view = (APP / 'Features/Workspace/RowPDFView.swift').read_text()
        # Overlay is drawn on the in-memory document only; never saved.
        self.assertNotIn('document.write', view)
        self.assertNotIn('dataRepresentation', view)

    def test_annotation_layer_has_no_row_count_path(self):
        for rel in ('Persistence/AnnotationRepository.swift', 'Domain/DocumentAnnotations.swift'):
            text = (APP / rel).read_text()
            self.assertNotIn('RowAction', text, rel)
        model = (APP / 'Features/Workspace/WorkspaceModel.swift').read_text()
        section = model.split('// MARK: - Document annotations', 1)[1].split('// MARK: - PDF import', 1)[0]
        self.assertNotIn('rowAction(', section)
        self.assertNotIn('completeRow', section)

    def test_store_and_backup_versions_and_deletion(self):
        factory = (APP / 'Persistence/RowStoreFactory.swift').read_text()
        self.assertIn('StoredDocumentAnnotation.self', factory)
        self.assertRegex(factory, r'schemaVersion = 8\b')
        fmt = (APP / 'Backup/BackupFormat.swift').read_text()
        self.assertRegex(fmt, r'public static let schemaVersion = 4\b')
        self.assertIn('decodeIfPresent([AnnotationSnapshot].self', fmt)
        self.assertIn('AnnotationRules.valid', fmt)
        backup = (APP / 'Backup/BackupRepository.swift').read_text()
        self.assertIn('storedAnnotations(documentIDs:', backup)
        self.assertIn('for object in annotations { context.delete(object) }', backup)

    def test_ui_is_button_operable_and_states_ownership(self):
        layout = (APP / 'Features/Workspace/WorkspaceLayout.swift').read_text()
        for ident in ('button.addAnnotation', 'field.annotationTitle', 'button.saveAnnotation'):
            self.assertIn(ident, layout)
        self.assertIn('Shared across every piece working from this pattern', layout)
        self.assertIn('model.navigate(to: item)', layout)

    def test_rules_bound_text_and_coordinates(self):
        text = (APP / 'Domain/DocumentAnnotations.swift').read_text()
        self.assertIn('isFinite', text)
        self.assertIn('<= 500', text)
        self.assertTrue(re.search(r'r\.x \+ r\.width <= 1', text))


if __name__ == '__main__':
    unittest.main()
