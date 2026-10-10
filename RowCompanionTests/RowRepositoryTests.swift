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

    // The CloudKit-disabled pin (`cloudKitDatabase: .none`) is enforced
    // structurally at the single `RowStoreFactory.configuration` call site —
    // `ModelConfiguration.CloudKitDatabase` is not public-Equatable, so a
    // runtime assertion here would only re-test the type system. The relaunch
    // tests above prove the store is durable *local* storage, and
    // Tests/test_row_domain_contract.py asserts the pin in source.

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

/// Library acceptance uses real disk stores, including the pre-library schema.
@MainActor
final class ProjectLibraryTests: XCTestCase {
    private func withStore(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("library.sqlite"))
    }

    func testStatusRenameSummaryAndLastWorkedSurviveRelaunch() throws {
        try withStore { url in
            let repo = try RowRepository(storeURL: url)
            let project = try repo.createProject(title: "Scarf")
            let piece = try repo.addPiece(to: project.id, name: "Body", repeatLength: 8)
            XCTAssertNil(try repo.librarySummaries().first?.lastWorkedAt)
            try repo.apply(.setRepeatLength(4), to: piece.id)
            XCTAssertNil(try repo.librarySummaries().first?.lastWorkedAt)
            try repo.apply(.completeRow, to: piece.id)
            try repo.renameProject(project.id, title: "  Winter scarf \n")
            for status in ProjectStatus.allCases { try repo.setProjectStatus(project.id, status: status) }
            let reopened = try RowRepository.open(storeURL: url)
            let summary = try XCTUnwrap(reopened.librarySummaries().first)
            XCTAssertEqual(summary.project.title, "Winter scarf")
            XCTAssertEqual(summary.status, .completed)
            XCTAssertEqual(summary.completedRows, 1)
            XCTAssertEqual(summary.pieceCount, 1)
            XCTAssertNotNil(summary.lastWorkedAt)
            XCTAssertThrowsError(try reopened.renameProject(project.id, title: " \n"))
        }
    }

    func testFreshDuplicateAndProgressDuplicateHaveIndependentConsistentHistory() throws {
        try withStore { url in
            let repo = try RowRepository(storeURL: url)
            let project = try repo.createProject(title: "Sweater")
            let piece = try repo.addPiece(to: project.id, name: "Front", repeatLength: 8, startingRows: 3)
            try repo.setNotes("Original fixture notes", on: piece.id)
            try repo.addReminder(to: piece.id, instruction: "Shape", interval: 2, startRow: 4)
            try repo.apply(.completeRow, to: piece.id)
            try repo.apply(.completeRow, to: piece.id)
            try repo.apply(.undo, to: piece.id)
            try repo.addCheckpoint(to: piece.id, name: "Ribbing")
            let freshID = try repo.duplicateProject(project.id, title: "Fresh")
            let fresh = try XCTUnwrap(repo.pieces(in: freshID).first)
            XCTAssertEqual(fresh.completedRows, 0)
            XCTAssertEqual(fresh.repeatLength, 8)
            XCTAssertEqual(fresh.notes, "Original fixture notes")
            XCTAssertTrue(try repo.history(for: fresh.id).isEmpty)
            XCTAssertTrue(try repo.checkpoints(for: fresh.id).isEmpty)
            XCTAssertNil(try repo.referenceState(for: fresh.id))
            XCTAssertEqual(try repo.reminders(for: fresh.id).count, 1)
            let copiedID = try repo.duplicateProject(project.id, title: "Progress", copyProgress: true)
            let copied = try XCTUnwrap(repo.pieces(in: copiedID).first)
            let history = try repo.history(for: copied.id)
            let sourceHistory = try repo.history(for: piece.id)
            XCTAssertEqual(copied.completedRows, 4)
            XCTAssertEqual(history.map(\.kind), sourceHistory.map(\.kind))
            XCTAssertTrue(Set(history.map(\.id)).isDisjoint(with: Set(sourceHistory.map(\.id))))
            XCTAssertEqual(history.last?.undoneEventID, history[1].id)
            XCTAssertEqual(try repo.checkpoints(for: copied.id).count, 1)
            try repo.apply(.undo, to: copied.id)
            XCTAssertEqual(try repo.piece(copied.id).completedRows, 3)
            XCTAssertEqual(try repo.piece(piece.id).completedRows, 4)
            let reopened = try RowRepository.open(storeURL: url)
            XCTAssertEqual(try reopened.piece(copied.id).completedRows, 3)
            _ = try BackupFormat.validate(manifest: reopened.projectSnapshot(for: copiedID), stagedDirectory: url.deletingLastPathComponent())
        }
    }

    func testLibrarySaveFailuresRollbackAllRecords() throws {
        try withStore { url in
            let repo = try RowRepository(storeURL: url)
            let project = try repo.createProject(title: "Original")
            let piece = try repo.addPiece(to: project.id, name: "Body")
            struct Fault: Error {}
            repo.testSaveFault = { throw Fault() }
            XCTAssertThrowsError(try repo.renameProject(project.id, title: "Changed"))
            XCTAssertThrowsError(try repo.setProjectStatus(project.id, status: .archived))
            XCTAssertThrowsError(try repo.duplicateProject(project.id, title: "Copy"))
            XCTAssertThrowsError(try repo.apply(.completeRow, to: piece.id))
            repo.testSaveFault = nil
            let reopened = try RowRepository.open(storeURL: url)
            XCTAssertEqual(try reopened.projects().map(\.title), ["Original"])
            XCTAssertEqual(try reopened.librarySummaries().first?.status, .active)
            XCTAssertNil(try reopened.librarySummaries().first?.lastWorkedAt)
            XCTAssertEqual(try reopened.piece(piece.id).completedRows, 0)
        }
    }

    func testActualPreLibrarySchemaMigratesWithoutLosingHistory() throws {
        try withStore { url in
            let id = UUID(), pieceID = UUID(), eventID = UUID()
            let date = Date(timeIntervalSince1970: 1000)
            // The old schema genuinely omits the new entity; changing a stamp
            // in a current-schema container would not exercise migration.
            do {
                let oldSchema = Schema([StoredProject.self, StoredPiece.self, StoredRowEvent.self,
                    StoredStoreInfo.self, StoredPatternDocument.self, StoredReferenceState.self,
                    StoredShapingReminder.self, StoredProgressCheckpoint.self])
                let config = ModelConfiguration("RowCompanion", schema: oldSchema, url: url, cloudKitDatabase: .none)
                let container = try ModelContainer(for: oldSchema, configurations: [config])
                let context = ModelContext(container)
                context.insert(StoredStoreInfo(schemaVersion: 5, createdAt: date))
                context.insert(StoredProject(id: id, title: "Legacy", createdAt: date, updatedAt: date))
                context.insert(StoredPiece(id: pieceID, projectID: id, name: "Body", completedRows: 1, repeatLength: 8, notes: "Fixture"))
                context.insert(StoredRowEvent(id: eventID, pieceID: pieceID, sequence: 1,
                    kind: .completeRow, before: 0, after: 1, createdAt: date, undoneEventID: nil))
                try context.save()
            }
            let migrated = try RowRepository.open(storeURL: url)
            let summary = try XCTUnwrap(migrated.librarySummaries().first)
            XCTAssertEqual(summary.status, .active)
            XCTAssertEqual(summary.lastWorkedAt, date)
            XCTAssertEqual(summary.completedRows, 1)
            XCTAssertEqual(try migrated.history(for: pieceID).first?.id, eventID)
            try migrated.setProjectStatus(id, status: .archived)
            let reopened = try RowRepository.open(storeURL: url)
            XCTAssertEqual(try reopened.librarySummaries().first?.status, .archived)
            let context = ModelContext(reopened.container)
            XCTAssertEqual(try context.fetch(FetchDescriptor<StoredStoreInfo>()).first?.schemaVersion, 6)
            try reopened.deleteProject(id, confirmed: true)
            XCTAssertTrue(try context.fetch(FetchDescriptor<StoredLibraryEntry>()).isEmpty)
        }
    }
}

extension ProjectLibraryTests {
    func testLargeLibraryBulkSummariesIncludeLegacyAndCachedDates() throws {
        try withStore { url in
            let repo = try RowRepository(storeURL: url)
            let context = ModelContext(repo.container)
            let date = Date(timeIntervalSince1970: 1000)
            var expected: [UUID: Date] = [:]
            for index in 0..<300 {
                let projectID = UUID()
                context.insert(StoredProject(id: projectID, title: "Project \(index)", createdAt: date, updatedAt: date))
                if index.isMultiple(of: 2) {
                    context.insert(StoredLibraryEntry(projectID: projectID, statusRaw: "archived", lastWorkedAt: date))
                    expected[projectID] = date
                } else { expected[projectID] = date.addingTimeInterval(19) }
                for _ in 0..<4 {
                    let pieceID = UUID()
                    context.insert(StoredPiece(id: pieceID, projectID: projectID, name: "Body", completedRows: 20, repeatLength: nil, notes: ""))
                    for sequence in 1...20 {
                        context.insert(StoredRowEvent(id: UUID(), pieceID: pieceID, sequence: sequence,
                            kind: .completeRow, before: sequence - 1, after: sequence,
                            createdAt: date.addingTimeInterval(Double(sequence - 1)), undoneEventID: nil))
                    }
                    context.insert(StoredRowEvent(id: UUID(), pieceID: pieceID, sequence: 21,
                        kind: .repeatLengthChange, before: 20, after: 20,
                        createdAt: date.addingTimeInterval(100), undoneEventID: nil))
                }
            }
            try context.save()
            let summaries = try repo.librarySummaries()
            XCTAssertEqual(summaries.count, 300)
            for summary in summaries {
                XCTAssertEqual(summary.pieceCount, 4)
                XCTAssertEqual(summary.completedRows, 80)
                XCTAssertEqual(summary.lastWorkedAt, expected[summary.id])
                XCTAssertEqual(summary.status, summary.lastWorkedAt == date ? .archived : .active)
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredLibraryEntry>()), 150, "Reading legacy dates must not insert metadata")
        }
    }
}
