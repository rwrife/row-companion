from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'
BACKUP = APP / 'Backup'


class BackupContractTests(unittest.TestCase):
    """Static source-contract checks for issue #5 (versioned backup/restore,
    privacy-safe deletion). These are NOT iOS build or simulator evidence —
    real acceptance runs in the pinned macOS CI job."""

    def test_backup_sources_exist_and_are_wired_into_project(self):
        names = sorted(p.name for p in APP.rglob('*.swift'))
        for expected in ('BackupFormat.swift', 'BackupRepository.swift',
                         'BackupService.swift', 'ByteCount.swift'):
            self.assertIn(expected, names)
        test_names = sorted(p.name for p in (ROOT / 'RowCompanionTests').glob('*.swift'))
        self.assertIn('BackupTests.swift', test_names)
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        for source in names + test_names:
            self.assertIn('path = ' + source, project)

    def test_format_constants_match_plan(self):
        text = (BACKUP / 'BackupFormat.swift').read_text()
        self.assertIn('maximumTotalBytes = 200 * 1024 * 1024', text)
        self.assertIn('public static let schemaVersion = 1', text)
        # Hostile-archive checks all exist as distinct failure modes.
        for case in ('case schemaTooNew', 'case traversalPath', 'case absolutePath',
                     'case symlink(', 'case duplicatePath', 'case duplicateID',
                     'case danglingReference', 'case invalidCountOrHistory',
                     'case hashMismatch', 'case sizeMismatch', 'case oversizedTotal'):
            self.assertIn(case, text)

    def test_default_export_carries_no_pdf_bytes_or_source_paths(self):
        service = (BACKUP / 'BackupService.swift').read_text()
        # Only two write paths: manifest JSON, and originals when explicitly
        # opted into (exportFullBackup). The progress export uses the
        # repository snapshot, which records only generated relative paths.
        self.assertIn('exportProgress', service)
        self.assertIn('exportFullBackup', service)
        snapshot = (BACKUP / 'BackupRepository.swift').read_text()
        self.assertIn('includesOriginals: false', snapshot)
        # The manifest path field is the app-generated relative path, never
        # the user's filename (import contract already enforces generated
        # names; re-assert the snapshot reads it from the record).
        self.assertIn('relativePath: doc.relativePath', snapshot)

    def test_originals_opt_in_requires_warning(self):
        service = (BACKUP / 'BackupService.swift').read_text()
        warnings = service[service.index('func warnings'):]
        warnings = warnings[:warnings.index('public static let deletionScopeNote')]
        self.assertIn('includingOriginals', warnings)
        self.assertIn('copyright', warnings.lower())
        # The UI gate: full-backup button disabled until acknowledged.
        content = (APP / 'ContentView.swift').read_text()
        self.assertIn('button.exportFullBackup', content)
        self.assertIn('fullBackupAcknowledged', content)
        self.assertIn('toggle.acknowledgeOriginals', content)

    def test_restore_stages_validates_and_creates_new_ids_only(self):
        service = (BACKUP / 'BackupService.swift').read_text()
        self.assertIn('func stageRestore', service)
        self.assertIn('func validate', service)
        self.assertIn('startAccessingSecurityScopedResource', service)
        self.assertIn('stopAccessingSecurityScopedResource', service)
        fmt = (BACKUP / 'BackupFormat.swift').read_text()
        self.assertIn('func remap', fmt)
        repo = (BACKUP / 'BackupRepository.swift').read_text()
        self.assertIn('func insertRestoredProject', repo)
        # No overwrite/merge entry points exist in the restore API.
        for forbidden in ('func overwrite', 'func merge'):
            self.assertNotIn(forbidden, service)
        # Any failure path removes the staging directory.
        self.assertIn('removeItem(at: staged)', service)

    def test_deletion_requires_confirmation_and_scopes_to_app_owned_files(self):
        repo = (BACKUP / 'BackupRepository.swift').read_text()
        self.assertIn('func deleteProject', repo)
        self.assertIn('deletionRequiresConfirmation', repo)
        self.assertIn('hasPrefix(documentsDir', repo)
        # Deletion scope honesty string exists for the UI.
        service = (BACKUP / 'BackupService.swift').read_text()
        self.assertIn('deletionScopeNote', service)
        content = (APP / 'ContentView.swift').read_text()
        self.assertIn('button.confirmDelete', content)

    def test_no_network_or_telemetry_or_cloudkit_on_backup_paths(self):
        for path in sorted(BACKUP.glob('*.swift')):
            text = path.read_text()
            # Code-level bans (comments may *name* the absent technologies
            # to document the audit, so match code shapes, not prose).
            for forbidden in ('URLSession', 'import CloudKit', 'import Network',
                              'import MessageUI', 'Analytics'):
                self.assertNotIn(forbidden, text, path.name)
        factory = (APP / 'Persistence' / 'RowStoreFactory.swift').read_text()
        self.assertIn('cloudKitDatabase: .none', factory)

    def test_ui_test_journey_covers_export_and_privacy_gates(self):
        smoke = (ROOT / 'RowCompanionUITests' / 'RowCompanionUITests.swift').read_text()
        self.assertIn('testDefaultExportRequiresAcknowledgementAndWritesMetadataOnly', smoke)
        self.assertIn('toggle.acknowledgeOriginals', smoke)
        self.assertIn('menu.export', smoke)

    def test_workspace_purity_backup_adds_no_row_action_path(self):
        # Backup entry points live above layout branches but must not gain
        # any RowAction construction (counts only move via explicit controls).
        for name in ('WorkspaceLayout.swift', 'WorkspaceArrangement.swift'):
            text = (APP / 'Features' / 'Workspace' / name).read_text()
            self.assertNotIn('RowAction(', text, name)
            self.assertNotIn('RowAction.', text, name)


if __name__ == '__main__':
    unittest.main()
