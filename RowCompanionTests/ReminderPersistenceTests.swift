import XCTest
import SwiftData
@testable import RowCompanion

/// Durable behavior of shaping reminders (issue #15): round trips, rejected
/// writes, and cleanup with project deletion.
@MainActor
final class ReminderPersistenceTests: XCTestCase {
    private var storeURL: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-reminder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("rowcompanion.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFixture() throws -> (RowRepository, PieceRecord) {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Sweater")
        let piece = try repo.addPiece(to: project.id, name: "Body", repeatLength: 8)
        return (repo, piece)
    }

    func testReminderRoundTripAndOrdering() throws {
        let (repo, piece) = try makeFixture()
        _ = try repo.addReminder(to: piece.id, instruction: "Increase every 6", interval: 6, startRow: 4, endRow: 60)
        _ = try repo.addReminder(to: piece.id, instruction: "Begin shaping", interval: nil, startRow: 48)
        let listed = try repo.reminders(for: piece.id)
        XCTAssertEqual(listed.map(\.instruction), ["Increase every 6", "Begin shaping"])
        XCTAssertEqual(listed.first?.interval, 6)
        XCTAssertEqual(listed.first?.endRow, 60)
        XCTAssertNil(listed.last?.interval)

        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.reminders(for: piece.id), listed)
    }

    func testInvalidRemindersNeverReachDisk() throws {
        let (repo, piece) = try makeFixture()
        for (instruction, interval, start, end) in [
            ("", nil, 4, nil), ("ok", 0, 4, nil), ("ok", nil, 0, nil), ("ok", 6, 10, 5),
        ] {
            XCTAssertThrowsError(
                try repo.addReminder(to: piece.id, instruction: instruction, interval: interval, startRow: start, endRow: end)
            ) { error in
                guard case RowRepositoryError.reminderInvalid = error as? RowRepositoryError else {
                    return XCTFail("expected reminderInvalid, got \(error)")
                }
            }
        }
        XCTAssertTrue(try repo.reminders(for: piece.id).isEmpty)
        // Nothing partially committed: relaunch sees the same empty set.
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertTrue(try relaunched.reminders(for: piece.id).isEmpty)
    }

    func testUnknownPieceIsRejected() throws {
        let (repo, _) = try makeFixture()
        XCTAssertThrowsError(
            try repo.addReminder(to: UUID(), instruction: "ok", interval: nil, startRow: 1)
        ) { error in
            guard case RowRepositoryError.pieceNotFound = error as? RowRepositoryError else {
                return XCTFail("expected pieceNotFound, got \(error)")
            }
        }
    }

    func testInjectedSaveFailureKeepsPriorReminderSet() throws {
        let (repo, piece) = try makeFixture()
        _ = try repo.addReminder(to: piece.id, instruction: "Keep me", interval: nil, startRow: 48)

        struct Injected: Error {}
        repo.testSaveFault = { throw Injected() }
        XCTAssertThrowsError(
            try repo.addReminder(to: piece.id, instruction: "Loser", interval: 6, startRow: 4)
        )
        repo.testSaveFault = nil

        XCTAssertEqual(try repo.reminders(for: piece.id).map(\.instruction), ["Keep me"])
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.reminders(for: piece.id).map(\.instruction), ["Keep me"])
    }

    func testRemoveReminderDurablyDeletes() throws {
        let (repo, piece) = try makeFixture()
        let keep = try repo.addReminder(to: piece.id, instruction: "Keep", interval: nil, startRow: 48)
        _ = try repo.addReminder(to: piece.id, instruction: "Drop", interval: nil, startRow: 10)
        try repo.removeReminder(id: keep.id)
        XCTAssertEqual(try repo.reminders(for: piece.id).map(\.instruction), ["Drop"])
        // Removing a missing id is a durable no-op, not an error.
        try repo.removeReminder(id: UUID())
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.reminders(for: piece.id).map(\.instruction), ["Drop"])
    }

    func testProjectDeletionRemovesReminders() throws {
        let (repo, piece) = try makeFixture()
        _ = try repo.addReminder(to: piece.id, instruction: "Gone with project", interval: nil, startRow: 48)
        let projectID = piece.projectID
        try repo.deleteProject(projectID, confirmed: true)
        let relaunched = try RowRepository.open(storeURL: storeURL)
        // No reminders survive for any piece id, verified through a fresh
        // unfiltered scan of the reminder table.
        let context = ModelContext(relaunched.container)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StoredShapingReminder>()).isEmpty)
    }

    /// Reminders are strictly piece-scoped: two pieces of the same project
    /// keep independent sets, and completing rows on one never affects the
    /// other's reminder surface.
    func testPiecesKeepIndependentReminderSets() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Two piece")
        let front = try repo.addPiece(to: project.id, name: "Front")
        let back = try repo.addPiece(to: project.id, name: "Back")
        _ = try repo.addReminder(to: front.id, instruction: "Front only", interval: 6, startRow: 4)
        XCTAssertEqual(try repo.reminders(for: front.id).count, 1)
        XCTAssertTrue(try repo.reminders(for: back.id).isEmpty)
        try repo.apply(.completeRow, to: back.id)
        XCTAssertEqual(try repo.reminders(for: front.id).count, 1)
        XCTAssertTrue(try repo.reminders(for: back.id).isEmpty)
    }

    /// Stores written before issue #15 (schema v2) must open cleanly and gain
    /// an empty reminder surface — prior counts and history stay untouched.
    func testOpeningPreReminderStoreWorksAndPreservesCounts() throws {
        let (repo, piece) = try makeFixture()
        try repo.apply(.completeRow, to: piece.id)
        try repo.apply(.completeRow, to: piece.id)
        // Stamp the store back to the pre-#15 version the way an old install
        // would have left it. SwiftData tolerates reading a store whose model
        // gained only *additive optional-free* entities; the version stamp is
        // ours to manage and the gate only rejects newer-than-known stores.
        let context = ModelContext(repo.container)
        let info = try context.fetch(FetchDescriptor<StoredStoreInfo>()).first!
        info.schemaVersion = 2
        try context.save()

        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.piece(piece.id).completedRows, 2)
        XCTAssertTrue(try relaunched.reminders(for: piece.id).isEmpty)
        _ = try relaunched.addReminder(to: piece.id, instruction: "New", interval: nil, startRow: 3)
        let again = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try again.reminders(for: piece.id).map(\.instruction), ["New"])
    }
}
