import json
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "RowCompanion"
ASSETS = APP / "Assets.xcassets"


def text(*parts):
    return (APP.joinpath(*parts)).read_text(encoding="utf-8")


PATTERN_SOURCE = text("Domain", "StarterPattern.swift")


class StarterCatalogContractTests(unittest.TestCase):
    def test_catalog_is_bundled_and_offline(self):
        # No networking type or entitlement may appear anywhere in the
        # catalog surface — first launch works without network or permission.
        surface = (
            PATTERN_SOURCE
            + text("Persistence", "RowRepository.swift")
            + text("Features", "Workspace", "WorkspaceModel.swift")
            + text("ContentView.swift")
        )
        for banned in ("URLSession", "NWConnection", "MFMail", "com.apple.developer.networking"):
            self.assertNotIn(banned, surface)
        # No iCloud container anywhere in the app, let alone the catalog.
        project = (ROOT / "RowCompanion.xcodeproj" / "project.pbxproj").read_text()
        entitlements = list(ROOT.glob("*.entitlements"))
        for source in [project] + [p.read_text() for p in entitlements]:
            self.assertNotIn("CloudKit", source)
            self.assertNotIn("icloud.com", source)

    def test_every_shipped_pattern_carries_full_provenance_fields(self):
        starts = [m.start() for m in re.finditer(r"StarterPattern\(\n", PATTERN_SOURCE)]
        self.assertGreaterEqual(len(starts), 2, "expected multiple shipped patterns")
        required = [
            "id:", "version:", "title:", "craft:", "difficulty:", "summary:",
            "finishedDimensions:", "materials:", "terminology:", "instructions:",
            "pieces:", "reviewState:", "author:", "license:",
            "previewImageName:", "previewAltText:", "previewProvenance:",
        ]
        for start in starts:
            block = PATTERN_SOURCE[start : PATTERN_SOURCE.find("\n        StarterPattern(", start + 1)]
            for field in required:
                self.assertIn(field, block, f"shipped pattern missing {field}")
            # Honest labelling requirements enforced by the Swift rules are
            # duplicated here so a content-only regression fails Linux CI too.
            self.assertIn("illustration", block)
            self.assertIn("gpt-image", block, "preview provenance must name the generating model")

    def test_preview_imagesets_exist_with_images_and_alt_sized_assets(self):
        names = re.findall(r'previewImageName: "([^"]+)"', PATTERN_SOURCE)
        self.assertTrue(names)
        for name in names:
            imageset = ASSETS / f"{name}.imageset"
            self.assertTrue(imageset.is_dir(), f"missing imageset {name}")
            contents = json.loads((imageset / "Contents.json").read_text())
            files = [e.get("filename") for e in contents["images"] if e.get("filename")]
            self.assertEqual(len(files), 1)
            image = imageset / files[0]
            self.assertTrue(image.is_file(), f"missing image file {files[0]}")
            # Bound the shipped binary weight (generated previews are 640 px).
            self.assertLess(image.stat().st_size, 150 * 1024)
            self.assertGreater(image.stat().st_size, 1024)

    def test_starting_a_pattern_copies_records_and_never_links_back(self):
        repository = text("Persistence", "RowRepository.swift")
        signature = repository.index("func startStarterPattern")
        start = repository[repository.index("let chosenTitle", signature) :]
        # Fresh identifiers and zero progress, one commit.
        self.assertIn("StoredProject(id: projectID", start)
        self.assertIn("completedRows: 0", start)
        self.assertIn("StoredPiece(", start)
        self.assertIn("StoredShapingReminder(", start)
        self.assertIn("try commit()", start)
        # Blueprint is iterated into fresh Stored* models, no pattern references.
        self.assertIn("for piece in pattern.pieces", start)
        self.assertIn("for reminder in piece.reminders", start)
        self.assertNotIn("pattern.id", start)
        for banned in ("catalogID", "patternID", "starterID", "schemaVersion"):
            self.assertNotIn(banned, start)

    def test_catalog_ui_uses_leaf_identifiers_and_honest_copy(self):
        content = text("ContentView.swift")
        self.assertIn('accessibilityIdentifier("catalog.start."', content)
        self.assertIn('accessibilityIdentifier("catalog.detail.reviewBadge")', content)
        # Review copy must never claim tested-ness for unreviewed drafts.
        rules = PATTERN_SOURCE
        self.assertIn("not yet reviewed or test-made", rules)

    def test_repeat_lengths_stay_in_domain_bounds(self):
        lengths = [int(v) for v in re.findall(r'StarterPieceSpec\(\n\s+name: "[^"]+",\n\s+repeatLength: (\d+)', PATTERN_SOURCE)]
        self.assertTrue(lengths)
        for value in lengths:
            self.assertGreaterEqual(value, 1)
            self.assertLessEqual(value, 10_000)


if __name__ == "__main__":
    unittest.main()
