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

    def test_dishcloth_square_arithmetic_is_consistent(self):
        # 20 sts and 40 rows per 10 cm: a 40-st 20 cm square needs 80
        # rows. Slice 1 shipped "40 rows" (a 10 cm piece) and a reminder
        # at row 20 — this pins the corrected numbers.
        block = PATTERN_SOURCE[PATTERN_SOURCE.index('id: "garter-dishcloth"'):]
        block = block[: block.index("\n        StarterPattern(", block.index('id: "garter-dishcloth"') + 1) if "\n        StarterPattern(" in block else len(block)]
        self.assertIn("until 80 rows are complete", block)
        self.assertNotIn("until 40 rows are complete", block)
        self.assertIn("startRow: 40", block)
        self.assertIn("40 sts and 80 rows", block)

    def _block(self, pattern_id):
        start = PATTERN_SOURCE.index(f'id: "{pattern_id}"')
        end = PATTERN_SOURCE.find("\n        StarterPattern(", start + 1)
        return PATTERN_SOURCE[start : end if end != -1 else len(PATTERN_SOURCE)]

    def test_catalog_ships_six_patterns_with_even_craft_split(self):
        starts = [m.start() for m in re.finditer(r"StarterPattern\(\n", PATTERN_SOURCE)]
        self.assertEqual(len(starts), 6)
        self.assertEqual(PATTERN_SOURCE.count("craft: .knitting"), 3)
        self.assertEqual(PATTERN_SOURCE.count("craft: .crochet"), 3)

    def test_headband_cast_on_is_multiple_of_four_and_length_pinned(self):
        block = self._block("ribbed-headband")
        # 20 sts is a multiple of 4 for *k2, p2*; 24 rows/10 cm gives 115
        # rows for ~48 cm. The reminder must fire BEFORE the bind-off so the
        # maker fits the band first.
        self.assertIn("Cast on 20 sts", block)
        self.assertIn("115 rows", block)
        self.assertIn("startRow: 100", block)

    def test_crochet_scarf_length_and_block_boundaries(self):
        block = self._block("single-crochet-scarf")
        # 20 rows / 10 cm: 280 rows = 140 cm; 20-row blocks divide 280.
        self.assertEqual(280 % 20, 0)
        self.assertIn("280 rows", block)
        self.assertIn("interval: 20, startRow: 20, endRow: 260", block)
        # Color changes belong to the previous block's last stitch, matching
        # the written instruction wording.
        self.assertIn("finish this row's last stitch with the next color", block)

    def test_crochet_dishcloth_square_arithmetic(self):
        block = self._block("single-crochet-dishcloth")
        # 18 sc / 10 cm and 20 rows / 10 cm: 36 sc and 40 rows = 20 cm square.
        self.assertAlmostEqual(36 / 18 * 10, 40 / 20 * 10, places=6)
        self.assertIn("36 sc and 40 rows", block)
        self.assertIn("startRow: 20", block)

    def test_second_slice_imagesets_present(self):
        # Slice 2 previews must be committed alongside their patterns, not
        # referenced optimistically.
        for name in ("StarterRibbedHeadband", "StarterCrochetScarf", "StarterCrochetDishcloth"):
            imageset = ASSETS / f"{name}.imageset"
            self.assertTrue(imageset.is_dir(), f"missing imageset {name}")


if __name__ == "__main__":
    unittest.main()
