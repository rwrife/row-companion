import XCTest
import SwiftData
@testable import RowCompanion

/// Persistence acceptance tests for the durable local repository.
/// Runs against a temporary on-disk store per test (CloudKit-disabled local
/// configuration — never an in-memory shortcut, so durability is real).
@MainActor
final class RowRepositoryTests: XCTestCase {
    private var storeURL: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-repo-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("rowcompanion.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCreateProjectAndPieceRoundTrip() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Scarf")
        let piece = try repo.addPiece(to: project.id, name: "front", repeatLength: 8)
        XCTAssertEqual(piece.completedRows, 0)
        XCTAssertEqual(try repo.pieces(in: project.id).map(\.name), ["front"])
        XCTAssertEqual(try repo.projects().map(\.title), ["Scarf"])
    }

    /// Relaunch durability: a *new* repository instance over the same store
    /// sees counts and full event history exactly as committed.
    func testRelaunchShowsCommittedCountsAndHistory() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Scarf")
        let piece = try repo.addPiece(to: project.id, name: "front", repeatLength: 8)
        try repo.apply(.completeRow, to: piece.id)
        try repo.apply(.completeRow, to: piece.id)
        try repo.apply(.undo, to: piece.id)

        // "Relaunch": fresh container + context over the same file.
        let relaunched = try RowRepository.open(storeURL: storeURL)
        let reloaded = try relaunched.piece(piece.id)
        XCTAssertEqual(reloaded.completedRows, 1)
        XCTAssertEqual(try relaunched.history(for: piece.id).map(\.kind), [.completeRow, .completeRow, .undo])
        XCTAssertEqual(try relaunched.history(for: piece.id).map(\.sequence), [1, 2, 3])
    }

    /// Atomicity under an injected save failure: neither the count nor the
    /// event may appear durable afterwards, and the error must not be
    /// swallowed into an apparent success.
    func testInjectedSaveFailureLeavesNoCommittedState() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Scarf")
        let piece = try repo.addPiece(to: project.id, name: "front", repeatLength: 8)
        try repo.apply(.completeRow, to: piece.id)   // committed baseline

        struct Injected: Error {}
        repo.testSaveFault = { throw Injected() }
        XCTAssertThrowsError(try repo.apply(.completeRow, to: piece.id)) { error in
            XCTAssertTrue(error is RowRepositoryError, "expected RowRepositoryError, got \(error)")
        }
        repo.testSaveFault = nil

        let current = try repo.piece(piece.id)
        XCTAssertEqual(current.completedRows, 1, "failed action must not display a committed counter update")
        XCTAssertEqual(try repo.history(for: piece.id).count, 1, "failed action must not leave an event")

        // And a relaunch sees the same un-diverged state.
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.piece(piece.id).completedRows, 1)
        XCTAssertEqual(try relaunched.history(for: piece.id).count, 1)
    }

    /// Event + count commit atomically in both directions: after a successful
    /// complete the durable pair is consistent (event.after == count).
    func testEventAndCountCommitAtomically() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Socks")
        let left = try repo.addPiece(to: project.id, name: "left", repeatLength: 8)
        let right = try repo.addPiece(to: project.id, name: "right", repeatLength: 8)

        for _ in 0..<3 { try repo.apply(.completeRow, to: left.id) }
        try repo.apply(.completeRow, to: right.id)

        let relaunched = try RowRepository.open(storeURL: storeURL)
        let leftPiece = try relaunched.piece(left.id)
        let rightPiece = try relaunched.piece(right.id)
        XCTAssertEqual(leftPiece.completedRows, 3)
        XCTAssertEqual(rightPiece.completedRows, 1)
        let leftHistory = try relaunched.history(for: left.id)
        XCTAssertEqual(leftHistory.last?.after, leftPiece.completedRows, "durable count matches final event")
        XCTAssertEqual(rightPiece.nextRepeatRow, 2)
        XCTAssertEqual(leftPiece.nextRepeatRow, 4)
    }

    /// Owned migration fixture: a store stamped with a future schema version
    /// must fail closed instead of reading data it does not understand.
    func testFutureSchemaVersionFixtureFailsClosed() throws {
        // Build the fixture directly with the same CloudKit-disabled config.
        let config = RowStoreFactory.configuration(storeURL: storeURL)
        let container = try ModelContainer(for: RowStoreFactory.schema, configurations: [config])
        let context = ModelContext(container)
        context.insert(StoredStoreInfo(schemaVersion: RowStoreFactory.schemaVersion + 5, createdAt: Date()))
        try context.save()

        do {
            _ = try RowRepository(storeURL: storeURL)
            XCTFail("future schema version must be rejected")
        } catch let error as RowRepositoryError {
            guard case .unsupportedSchemaVersion(let found) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, RowStoreFactory.schemaVersion + 5)
        }
    }

    /// Current-version fixture opens normally (positive control for the test
    /// above: the rejection is version-specific, not "reopen always fails").
    func testCurrentSchemaFixtureReopens() throws {
        let repo = try RowRepository(storeURL: storeURL)
        _ = try repo.createProject(title: "Keep")
        let reopened = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try reopened.projects().count, 1)
    }

    func testStoreConfigurationDisablesCloudKit() throws {
        let config = RowStoreFactory.configuration(storeURL: storeURL)
        var isNone = false
        if case .none = config.cloudKitDatabase { isNone = true }
        XCTAssertTrue(isNone, "local store must never enable CloudKit mirroring")
    }

    func testUnknownPieceIsRejected() throws {
        let repo = try RowRepository(storeURL: storeURL)
        XCTAssertThrowsError(try repo.apply(.completeRow, to: UUID())) { error in
            XCTAssertTrue(error is RowRepositoryError)
        }
    }

    func testUndoDurabilityAcrossRelaunch() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Blanket")
        let piece = try repo.addPiece(to: project.id, name: "body")
        try repo.apply(.completeRow, to: piece.id)
        try repo.apply(.correction(to: 10, confirmed: true), to: piece.id)
        try repo.apply(.undo, to: piece.id)

        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.piece(piece.id).completedRows, 1, "correction undone back to its before-count")
        // The completed row that pre-dates the correction remains the only
        // eligible target; the undone correction cannot be reversed twice.
        try relaunched.apply(.undo, to: piece.id)
        XCTAssertEqual(try relaunched.piece(piece.id).completedRows, 0)
        XCTAssertThrowsError(try relaunched.apply(.undo, to: piece.id)) { error in
            XCTAssertEqual(error as? RowDomainError, .nothingToUndo)
        }
    }
}
