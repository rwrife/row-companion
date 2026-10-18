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
        XCTAssertFalse(knits.isEmpty)
        XCTAssertFalse(crochets.isEmpty)
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
