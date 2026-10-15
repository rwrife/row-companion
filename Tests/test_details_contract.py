import pathlib
import re
import unittest

APP = pathlib.Path(__file__).resolve().parents[1] / "RowCompanion"


def text(rel):
    return (APP / rel).read_text(encoding="utf-8")


class DetailsContract(unittest.TestCase):
    def test_store_is_additive_and_canonical_metric(self):
        factory = text("Persistence/RowStoreFactory.swift")
        self.assertIn("StoredProjectDetails.self", factory)
        self.assertRegex(factory, r"schemaVersion = 9")
        domain = text("Domain/ProjectDetails.swift")
        for field in ("toolSizeMM", "gaugeStitchesPer10CM", "measurementMM"):
            self.assertIn(field, domain)
        self.assertIn("millimetresPerInch = 25.4", domain)

    def test_backup_round_trips_details_and_rejects_dangling_owner(self):
        fmt = text("Backup/BackupFormat.swift")
        self.assertIn("decodeIfPresent([DetailsSnapshot]", fmt)
        self.assertIn("seenDetailOwners", fmt)
        self.assertRegex(fmt, r"manifest\.details\.map[\s\S]*?mapped\(entry\.ownerID\)")
        repo = text("Backup/BackupRepository.swift")
        self.assertIn("storedDetails(ownerIDs:", repo)
        self.assertIn("detailRows", repo)
        self.assertIn("StoredProjectDetails(ownerID: entry.ownerID", repo)

    def test_duplicate_copies_details_and_ui_has_unit_toggle(self):
        self.assertIn("StoredProjectDetails(ownerID: newID", text("Persistence/RowRepository.swift"))
        layout = text("Features/Workspace/WorkspaceLayout.swift")
        for ident in ("details.imperial", "details.scope", "details.save", "button.editDetails"):
            self.assertIn(ident, layout)

    def test_no_new_permission_surface(self):
        sources = "\n".join(p.read_text(encoding="utf-8") for p in APP.rglob("*.swift"))
        for forbidden in ("PhotosPicker", "PHPhotoLibrary", "requestAuthorization", "URLSession"):
            self.assertNotIn(forbidden, sources)

    def test_pbxproj_wires_new_files(self):
        project = (APP.parent / "RowCompanion.xcodeproj/project.pbxproj").read_text()
        for name in ("ProjectDetails.swift", "DetailsRepository.swift", "ProjectDetailsTests.swift"):
            self.assertEqual(len(re.findall(r"/\* %s in Sources \*/ = \{isa = PBXBuildFile" % re.escape(name), project)), 1)


if __name__ == "__main__":
    unittest.main()
