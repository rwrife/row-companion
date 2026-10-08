from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'


class CheckpointContractTests(unittest.TestCase):
    """Static source-contract checks for issue #18 (row history and named
    progress checkpoints). Acceptance runs in the pinned macOS CI job."""

    def test_checkpoint_sources_exist_and_are_wired_into_project(self):
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        for source in ('CheckpointModels.swift', 'CheckpointRepository.swift',
                       'CheckpointRulesTests.swift', 'CheckpointPersistenceTests.swift'):
            self.assertIn('path = ' + source, project)
            self.assertIn(source + ' in Sources', project)
        self.assertTrue((APP / 'Domain' / 'CheckpointModels.swift').is_file())
        self.assertTrue((APP / 'Persistence' / 'CheckpointRepository.swift').is_file())
        self.assertTrue((ROOT / 'RowCompanionTests' / 'CheckpointRulesTests.swift').is_file())
        self.assertTrue((ROOT / 'RowCompanionTests' / 'CheckpointPersistenceTests.swift').is_file())

    def test_checkpoint_rules_reuse_plan_row_bounds(self):
        text = (APP / 'Domain' / 'CheckpointModels.swift').read_text()
        self.assertIn('RowArithmetic.isValid(completedRows:', text)

    def test_checkpoint_layer_has_no_arbitrary_count_mutation(self):
        # Checkpoint restoration applies a confirmed correction through
        # RowAction.correction, never direct count writes.
        domain_text = (APP / 'Domain' / 'CheckpointModels.swift').read_text()
        self.assertNotIn('RowAction.completeRow', domain_text)

    def test_checkpoints_migrate_with_store_version(self):
        factory = (APP / 'Persistence' / 'RowStoreFactory.swift').read_text()
        self.assertIn('StoredProgressCheckpoint.self', factory)
        self.assertIn('schemaVersion = 5', factory)

    def test_project_deletion_removes_checkpoints(self):
        backup = (APP / 'Backup' / 'BackupRepository.swift').read_text()
        self.assertIn('storedCheckpoints(pieceIDs:', backup)
        self.assertIn('for object in checkpoints { context.delete(object) }', backup)

    def test_ui_journey_targets_checkpoint_and_history_controls(self):
        layout = (APP / 'Features' / 'Workspace' / 'WorkspaceLayout.swift').read_text()
        smoke = (ROOT / 'RowCompanionUITests' / 'RowCompanionUITests.swift').read_text()
        for identifier in ('button.addCheckpoint', 'button.checkpoint.save',
                           'field.checkpoint.name', 'button.checkpoint.restore',
                           'button.confirmRestoreCheckpoint', 'history.timeline'):
            self.assertIn(identifier, layout, 'layout missing ' + identifier)
            self.assertIn(identifier, smoke, 'journey missing ' + identifier)
        self.assertIn('testRowHistoryAndProgressCheckpointLifecycle', smoke)


if __name__ == '__main__':
    unittest.main()
