import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "RowCompanion"


def text(path):
    return (APP / path).read_text(encoding="utf-8")


class CounterContractTests(unittest.TestCase):
    def test_linked_counter_changes_commit_with_the_row_event(self):
        repository = text("Persistence/RowRepository.swift")
        self.assertIn("func counterChanges", text("Persistence/CounterRepository.swift"))
        self.assertRegex(repository, r"case \.completeRow, \.undo:\s*\n\s*counterChanges = try self\.counterChanges")
        self.assertRegex(repository, r"for \(counter, cEvent\) in counterChanges \{[\s\S]*?try commit\(\)")
        # Linked action is not an independent UI shortcut: the normal row action owns it.
        self.assertNotIn("applyLinked", repository + text("Features/Workspace/WorkspaceModel.swift"))

    def test_link_is_explicit_and_affected_group_is_visible(self):
        layout = text("Features/Workspace/WorkspaceLayout.swift")
        model = text("Features/Workspace/WorkspaceModel.swift")
        self.assertIn("field.counter.name", layout)
        self.assertIn("toggle.counter.composerLink", layout)
        self.assertIn("counter.linkedGroup", layout)
        self.assertIn("linkedCounterNames", model)
        self.assertIn('Complete row and Undo also change:', layout)

    def test_completed_row_counter_semantics_remain_intact(self):
        model = text("Domain/RowModels.swift")
        self.assertIn("public var completedRows: Int", model)
        self.assertNotIn("counterIDs", model)

    def test_counters_migrate_without_changing_history_and_backup_preserves_ids(self):
        factory = text("Persistence/RowStoreFactory.swift")
        backup = text("Backup/BackupFormat.swift")
        self.assertRegex(factory, r"schemaVersion = (9|10)")
        self.assertIn("StoredNamedCounter.self, StoredCounterEvent.self", factory)
        self.assertRegex(backup, r"schemaVersion = (5|6)")
        self.assertIn("decodeIfPresent([CounterSnapshot]", backup)
        self.assertIn("decodeIfPresent([CounterEventSnapshot]", backup)
        self.assertIn("counter \\(", backup)
        self.assertRegex(backup, r"counterEvents = manifest\.counterEvents\.map[\s\S]*?rowEventID: event\.rowEventID\.map")

    def test_no_network_or_permission_surface_was_added(self):
        sources = "\n".join(str(p.read_text(encoding="utf-8"))
                            for p in APP.rglob("*.swift"))
        for forbidden in ("URLSession", "import CloudKit", "NSUbiquitous", "requestAuthorization"):
            self.assertNotIn(forbidden, sources)
        self.assertNotIn("com.apple.security.network", (ROOT / "RowCompanion.xcodeproj/project.pbxproj").read_text())


if __name__ == "__main__":
    unittest.main()
