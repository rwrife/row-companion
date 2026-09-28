from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "RowCompanion"


class WorkspaceResumeContractTests(unittest.TestCase):
    """Host wiring contracts for issue #13; not iOS runtime evidence."""

    def test_session_model_and_repository_are_durable_and_separate_from_rows(self):
        models = (APP / "Domain" / "RowModels.swift").read_text()
        records = (APP / "Persistence" / "RowRecords.swift").read_text()
        repository = (APP / "Persistence" / "RowRepository.swift").read_text()
        factory = (APP / "Persistence" / "RowStoreFactory.swift").read_text()

        self.assertIn("struct WorkspaceSessionRecord", models)
        self.assertIn("final class StoredWorkspaceSession", records)
        self.assertIn("func workspaceSession()", repository)
        self.assertIn("func saveWorkspaceSession", repository)
        self.assertIn("StoredWorkspaceSession.self", factory)
        self.assertIn("schemaVersion = 3", factory)
        self.assertNotIn("RowAction", models.split("struct WorkspaceSessionRecord", 1)[1])

    def test_model_restores_and_captures_session_without_row_actions(self):
        model = (APP / "Features" / "Workspace" / "WorkspaceModel.swift").read_text()
        self.assertIn("restoreSessionOrFirstProject", model)
        self.assertIn("captureCurrentWorkspace", model)
        self.assertIn("setControlScrollOffset", model)
        self.assertIn("repository.workspaceSession()", model)
        self.assertIn("repository.saveWorkspaceSession", model)
        self.assertIn("if !readFailed", model)
        self.assertIn("persistReference(reference)", model)

        resume_surface = model.split("// MARK: - Session restore", 1)[1].split(
            "// MARK: - Mutation", 1
        )[0]
        self.assertNotIn("RowAction", resume_surface)
        self.assertNotIn("repository.apply", resume_surface)

    def test_lifecycle_and_scroll_restore_are_wired(self):
        content = (APP / "ContentView.swift").read_text()
        layout = (APP / "Features" / "Workspace" / "WorkspaceLayout.swift").read_text()

        self.assertIn('@Environment(\\.scenePhase)', content)
        self.assertIn("model.captureCurrentWorkspace()", content)
        self.assertIn("ScrollPosition(edge: .top)", layout)
        self.assertIn("onScrollGeometryChange", layout)
        self.assertIn("model.setControlScrollOffset", layout)
        self.assertIn('accessibilityIdentifier("workspace.controlsScroll")', layout)

    def test_native_session_and_relaunch_tests_exist(self):
        repository_tests = (
            ROOT / "RowCompanionTests" / "RowRepositoryTests.swift"
        ).read_text()
        ui_tests = (
            ROOT / "RowCompanionUITests" / "RowCompanionUITests.swift"
        ).read_text()

        for name in (
            "testWorkspaceSessionRoundTripsAcrossRelaunch",
            "testWorkspaceSessionRejectsPieceFromAnotherProject",
            "testWorkspaceSessionFailedSavePreservesPriorValue",
            "testVersionTwoStoreMigratesAndRestamps",
        ):
            self.assertIn(name, repository_tests)
        self.assertIn("testLastWorkspaceRestoresAcrossBackgroundAndRelaunch", ui_tests)
        reference_tests = (
            ROOT / "RowCompanionTests" / "ReferenceStateTests.swift"
        ).read_text()
        self.assertIn("testModelFallsBackWhenStoredSessionItemsAreMissing", reference_tests)
        self.assertIn("fallback must not touch counts", reference_tests)


if __name__ == "__main__":
    unittest.main()
