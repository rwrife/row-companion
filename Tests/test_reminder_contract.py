from pathlib import Path
import unittest
import re

# Schema versions may grow as additive piece-scoped models land.

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'RowCompanion'


class ReminderContractTests(unittest.TestCase):
    """Static source-contract checks for issue #15 (row milestones and
    recurring shaping reminders). These are NOT iOS build or simulator
    evidence — real acceptance runs in the pinned macOS CI job."""

    def test_reminder_sources_exist_and_are_wired_into_project(self):
        project = (ROOT / 'RowCompanion.xcodeproj/project.pbxproj').read_text()
        for source in ('ReminderModels.swift', 'ReminderRepository.swift',
                       'ReminderRulesTests.swift', 'ReminderPersistenceTests.swift'):
            self.assertIn('path = ' + source, project)
            self.assertIn(source + ' in Sources', project)
        self.assertTrue((APP / 'Domain' / 'ReminderModels.swift').is_file())
        self.assertTrue((APP / 'Persistence' / 'ReminderRepository.swift').is_file())
        self.assertTrue((ROOT / 'RowCompanionTests' / 'ReminderRulesTests.swift').is_file())
        self.assertTrue((ROOT / 'RowCompanionTests' / 'ReminderPersistenceTests.swift').is_file())

    def test_reminder_rules_reuse_plan_row_bounds(self):
        text = (APP / 'Domain' / 'ReminderModels.swift').read_text()
        # Milestone rows live in the completed-row domain...
        self.assertIn('RowArithmetic.maximumCompletedRows', text)
        # ...and a recurring interval reuses the repeat-length domain.
        self.assertIn('RowArithmetic.isValid(repeatLength:', text)

    def test_crossing_notice_is_capped_and_never_silent(self):
        text = (APP / 'Domain' / 'ReminderModels.swift').read_text()
        self.assertIn('displayCap', text)
        self.assertIn('hiddenCount', text)
        # Hidden milestones must be announced, never dropped silently.
        self.assertIn('more in the reminder list', text)

    def test_reminders_require_no_notification_permission(self):
        # The whole app surface must stay free of UserNotifications: due
        # state derives from the durable row count, never from scheduled
        # notifications.
        for path in ROOT.rglob('*.swift'):
            if '.git' in path.parts:
                continue
            text = path.read_text()
            self.assertNotIn('UserNotifications', text, path.name)
            self.assertNotIn('UNUserNotificationCenter', text, path.name)

    def test_reminder_layer_has_no_row_count_path(self):
        # Reminders are display/configuration state: neither the pure rules
        # nor the repository extension may construct or apply row actions,
        # so an edit to a reminder can never change a count.
        for name in ('Domain/ReminderModels.swift', 'Persistence/ReminderRepository.swift'):
            text = (APP / name).read_text()
            self.assertNotIn('RowAction(', text, name)
            self.assertNotIn('RowAction.', text, name)
            self.assertNotIn('apply(', text, name)
        model = (APP / 'Features' / 'Workspace' / 'WorkspaceModel.swift').read_text()
        section = model.split('// MARK: - Shaping reminders', 1)[1].split('// MARK: - PDF import', 1)[0]
        self.assertIn('addReminder', section)
        self.assertIn('removeReminder', section)
        self.assertNotIn('rowAction(', section)

    def test_project_deletion_removes_reminders(self):
        backup = (APP / 'Backup' / 'BackupRepository.swift').read_text()
        self.assertIn('storedReminders(pieceIDs:', backup)
        self.assertIn('for object in reminders { context.delete(object) }', backup)

    def test_reminders_migrate_with_store_version(self):
        factory = (APP / 'Persistence' / 'RowStoreFactory.swift').read_text()
        self.assertIn('StoredShapingReminder.self', factory)
        # v3 is reserved for the session model (issue #13); #15 lands at 4; #18 at 5.
        self.assertTrue(re.search(r'schemaVersion\s*=\s*[45]', factory), factory)

    def test_ui_journey_targets_reminder_controls(self):
        layout = (APP / 'Features' / 'Workspace' / 'WorkspaceLayout.swift').read_text()
        smoke = (ROOT / 'RowCompanionUITests' / 'RowCompanionUITests.swift').read_text()
        for identifier in ('button.addReminder', 'button.reminder.save',
                           'field.reminder.instruction', 'field.reminder.startRow',
                           'reminder.dueBanner', 'reminder.crossingNotice',
                           'reminder.reached'):
            self.assertIn(identifier, layout, 'layout missing ' + identifier)
            self.assertIn(identifier, smoke, 'journey missing ' + identifier)
        self.assertIn('testShapingReminderDueBannerCrossingAndRelaunch', smoke)


if __name__ == '__main__':
    unittest.main()
