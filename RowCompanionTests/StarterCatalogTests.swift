import XCTest
import SwiftData
@testable import RowCompanion

/// Host-side contract tests for the bundled starter catalog (issue #22).
///
/// Verifies every shipped pattern passes the same validation rules that gate
/// user-started projects, so malformed or over-limit content fails CI before
/// it can be presented in the UI.
@MainActor
final class StarterCatalogTests: XCTestCase {
    func testAllBundledPatternsAreWellFormed() {
        XCTAssertFalse(StarterCatalog.patterns.isEmpty, "The catalog must ship at least one pattern.")
        for pattern in StarterCatalog.patterns {
            let problems = StarterCatalogRules.validationProblems(for: pattern)
            XCTAssertTrue(problems.isEmpty, "Pattern \(pattern.id): \(problems)")
        }
    }

    func testPatternIDsAreUnique() {
        let ids = StarterCatalog.patterns.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate pattern ids found.")
    }

    func testSearchMatchIsCaseInsensitive() {
        let scarf = StarterCatalog.patterns.first(where: { $0.id == "garter-scarf" })
        XCTAssertNotNil(scarf)
        XCTAssertTrue(StarterCatalogRules.matches(scarf!, search: "SCARF"))
        XCTAssertTrue(StarterCatalogRules.matches(scarf!, search: "worsted"))
        XCTAssertFalse(StarterCatalogRules.matches(scarf!, search: "silk"))
    }

    func testCraftFilterWorks() {
        let knits = StarterCatalog.patterns.filter { $0.craft == .knitting }
        let crochets = StarterCatalog.patterns.filter { $0.craft == .crochet }
        XCTAssertEqual(knits.count, 3, "Expected three knit patterns.")
        XCTAssertEqual(crochets.count, 3, "Expected three crochet patterns.")
        XCTAssertEqual(StarterCatalog.patterns.count, 6, "Expected six shipped patterns.")
    }

    func testRibbedHeadbandStitchCountMultipleOfFour() throws {
        let headband = try XCTUnwrap(StarterCatalog.patterns.first { $0.id == "ribbed-headband" })
        // Cast-on 20 sts is a multiple of 4: *k2, p2* ends cleanly on p2.
        // Sample gauge 20 sts / 10 cm gives 10 cm width; 24 rows / 10 cm gives
        // ~115 rows for 48 cm.
        XCTAssertEqual(20 % 4, 0)
        XCTAssertTrue(headband.instructions.joined(separator: " ").contains("20 sts"))
        XCTAssertTrue(headband.instructions.joined(separator: " ").contains("115 rows"))
        XCTAssertEqual(headband.pieces[0].repeatLength, 2)
    }

    func testCrochetScarfLengthAndBlockArithmetic() throws {
        let scarf = try XCTUnwrap(StarterCatalog.patterns.first { $0.id == "single-crochet-scarf" })
        // 16 sc / 10 cm: 29 sc is ~18 cm width.
        // 20 rows / 10 cm: 280 rows is 140 cm length (280 / 20 * 10 = 140).
        // 20-row blocks evenly divide 280 (14 blocks total).
        XCTAssertEqual(280 % 20, 0)
        XCTAssertEqual(280 / 20, 14)
        XCTAssertTrue(scarf.instructions.joined(separator: " ").contains("280 rows"))
        let reminders = scarf.pieces[0].reminders
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].interval, 20)
        XCTAssertEqual(reminders[0].startRow, 20)
        XCTAssertEqual(reminders[0].endRow, 260)
    }

    func testCrochetDishclothSquareArithmetic() throws {
        let dishcloth = try XCTUnwrap(StarterCatalog.patterns.first { $0.id == "single-crochet-dishcloth" })
        // 18 sc / 10 cm: 36 sc is 20 cm.
        // 20 rows / 10 cm: 40 rows is 20 cm.
        // 36 sc and 40 rows make a true 20 cm square at sample gauge.
        let stitches = 36
        let rows = 40
        XCTAssertEqual(Double(stitches) / 18 * 10, Double(rows) / 20 * 10)
        XCTAssertTrue(dishcloth.instructions.joined(separator: " ").contains("36 sc"))
        XCTAssertTrue(dishcloth.instructions.joined(separator: " ").contains("40 rows"))
        XCTAssertEqual(dishcloth.pieces[0].reminders[0].startRow, 20)
    }

    func testDishclothRowCountMatchesSquareGauge() throws {
        let dishcloth = try XCTUnwrap(StarterCatalog.patterns.first { $0.id == "garter-dishcloth" })
        // 20 stitches / 10 cm and 40 rows / 10 cm: 40 stitches
        // need 80 rows for a 20 cm square, not 40 rows.
        let stitches = 40
        let rows = 80
        XCTAssertEqual(Double(stitches) / 20 * 10, Double(rows) / 40 * 10)
        XCTAssertTrue(dishcloth.instructions.joined(separator: " ").contains("80 rows"))
        XCTAssertTrue(dishcloth.pieces[0].instructions.contains("80 rows"))
        XCTAssertEqual(dishcloth.pieces[0].reminders[0].startRow, rows / 2)
    }
}

/// Persistence tests for starting a project from a starter pattern.
@MainActor
final class StarterProjectTests: XCTestCase {
    private var storeURL: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-starter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("rowcompanion.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testStartStarterPatternCreatesIndependentProject() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let pattern = StarterCatalog.patterns.first!
        let projectID = try repo.startStarterPattern(pattern)

        let pieces = try repo.pieces(in: projectID)
        XCTAssertEqual(pieces.count, pattern.pieces.count)
        XCTAssertEqual(pieces.map(\.name).sorted(), pattern.pieces.map(\.name).sorted())
        // All pieces start at zero completed rows.
        XCTAssertTrue(pieces.allSatisfy { $0.completedRows == 0 })
        // Written instructions are stored as piece notes (editable, not linked).
        for piece in pieces {
            XCTAssertFalse(piece.notes.isEmpty, "Piece \(piece.name) should have instructions in notes.")
        }
        // Reminders are present if the pattern defines any.
        for piece in pieces {
            let reminders = try repo.reminders(for: piece.id)
            let patternPiece = pattern.pieces.first(where: { $0.name == piece.name })
            XCTAssertEqual(reminders.count, patternPiece?.reminders.count ?? 0)
        }
        // Durable: relaunch proves it survived.
        let relaunched = try RowRepository.open(storeURL: storeURL)
        let relaunchPieces = try relaunched.pieces(in: projectID)
        XCTAssertEqual(relaunchPieces.count, pieces.count)
    }

    func testBundledPatternProjectBackupRestoreKeepsReminders() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let pattern = try XCTUnwrap(StarterCatalog.patterns.first { $0.id == "single-crochet-scarf" })
        let projectID = try repo.startStarterPattern(pattern)
        let originalPiece = try XCTUnwrap(try repo.pieces(in: projectID).first)
        let before = try repo.reminders(for: originalPiece.id)
        XCTAssertEqual(before.count, 1)

        let service = BackupService(repository: repo)
        let directory = tempDir.appendingPathComponent("starter-backup", isDirectory: true)
        try service.exportFullBackup(for: projectID, to: directory)
        let restoredID = try service.restore(from: directory)
        let restoredPiece = try XCTUnwrap(try repo.pieces(in: restoredID).first)
        XCTAssertEqual(restoredPiece.notes, originalPiece.notes)
        XCTAssertEqual(restoredPiece.repeatLength, originalPiece.repeatLength)
        let after = try repo.reminders(for: restoredPiece.id)
        XCTAssertEqual(after.map(\.instruction), before.map(\.instruction))
        XCTAssertEqual(after.map(\.startRow), before.map(\.startRow))
        XCTAssertEqual(after.map(\.endRow), before.map(\.endRow))
        XCTAssertNotEqual(after.first?.id, before.first?.id)
        XCTAssertEqual(try repo.reminders(for: originalPiece.id).count, 1)
    }

    func testInvalidPatternNeverReachesDisk() throws {
        let repo = try RowRepository(storeURL: storeURL)
        // Build a deliberately invalid pattern (no pieces).
        let bad = StarterPattern(
            id: "bad-pattern",
            version: 1,
            title: "Bad",
            craft: .knitting,
            difficulty: "Beginner",
            summary: "Missing pieces.",
            finishedDimensions: "n/a",
            materials: "n/a",
            gauge: nil,
            yarnEstimate: nil,
            terminology: "n/a",
            instructions: ["Do nothing."],
            pieces: [],
            previewImageName: nil,
            previewAltText: nil,
            reviewState: .draftUnreviewed,
            author: "Test",
            license: "MIT",
            previewProvenance: nil
        )
        XCTAssertThrowsError(try repo.startStarterPattern(bad))
        // No orphan projects.
        XCTAssertTrue(try repo.projects().isEmpty)
    }
}
