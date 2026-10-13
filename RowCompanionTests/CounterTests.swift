import XCTest
import SwiftData
@testable import RowCompanion

@MainActor
final class CounterTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rc-counters-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("store.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLinkedCommitUndoAndIndependentCountersSurviveReopen() throws {
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Sweater")
        let front = try repo.addPiece(to: project.id, name: "Front", repeatLength: 8)
        let back = try repo.addPiece(to: project.id, name: "Back")
        let linked = try repo.addCounter(to: front.id, name: "Motif", unit: "repeats", startingValue: 7,
                                         repeatLength: 8, advancesWithRows: true)
        let separate = try repo.addCounter(to: front.id, name: "Stitches", unit: "stitches", startingValue: 42)
        _ = try repo.addCounter(to: back.id, name: "Motif", unit: "repeats", startingValue: 3)
        let row = try XCTUnwrap(repo.apply(.completeRow, to: front.id))
        XCTAssertEqual(try repo.requireCounter(linked.id).value, 8)
        XCTAssertEqual(try repo.requireCounter(linked.id).record.nextRepeat, 1)
        XCTAssertEqual(try repo.requireCounter(separate.id).value, 42)
        XCTAssertEqual(try repo.counterHistory(for: linked.id).first?.rowEventID, row.id)
        try repo.setCounterLink(linked.id, advancesWithRows: false)
        _ = try repo.apply(.undo, to: front.id)
        XCTAssertEqual(try repo.requireCounter(linked.id).value, 7, "undo reverses original group even after link changed")
        XCTAssertEqual(try repo.requireCounter(separate.id).value, 42)
        XCTAssertEqual(try repo.piece(back.id).completedRows, 0)
        let reopened = try RowRepository.open(storeURL: url)
        XCTAssertEqual(try reopened.counters(for: front.id).count, 2)
        XCTAssertEqual(try reopened.counterHistory(for: linked.id).map(\.kind), [.advance, .undo])
        XCTAssertEqual(try reopened.history(for: front.id).map(\.kind), [.completeRow, .undo])
    }

    func testInjectedSaveFailureLeavesWholeLinkedActionUnchanged() throws {
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Scarf")
        let piece = try repo.addPiece(to: project.id, name: "Body")
        let linked = try repo.addCounter(to: piece.id, name: "Pattern", unit: "rows", advancesWithRows: true)
        repo.testSaveFault = { throw RowRepositoryError.counterInvalid }
        XCTAssertThrowsError(try repo.apply(.completeRow, to: piece.id))
        repo.testSaveFault = nil
        let reopened = try RowRepository.open(storeURL: url)
        XCTAssertEqual(try reopened.piece(piece.id).completedRows, 0)
        XCTAssertEqual(try reopened.requireCounter(linked.id).value, 0)
        XCTAssertTrue(try reopened.history(for: piece.id).isEmpty)
        XCTAssertTrue(try reopened.counterHistory(for: linked.id).isEmpty)
    }

    func testCorrectionResetAndBackupRoundTrip() throws {
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Sock")
        let piece = try repo.addPiece(to: project.id, name: "Heel")
        let counter = try repo.addCounter(to: piece.id, name: "Cable", unit: "motifs", startingValue: 2, repeatLength: 4)
        _ = try repo.advanceCounter(counter.id)
        _ = try repo.changeCounter(counter.id, to: 9, confirmed: true)
        _ = try repo.changeCounter(counter.id, to: 2, confirmed: true, reset: true)
        XCTAssertThrowsError(try repo.changeCounter(counter.id, to: 3000000, confirmed: true))
        let data = try BackupService(repository: repo).exportProgress(for: project.id)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupFormat.Manifest.self, from: data)
        XCTAssertEqual(manifest.counters.count, 1)
        XCTAssertEqual(manifest.counterEvents.map(\.kind), [.advance, .correction, .reset])
        let bundle = BackupFormat.remap(BackupFormat.ValidatedRestore(manifest: manifest, documentBytes: [:]), newIDs: { UUID() })
        let copyID = try repo.insertRestoredProject(bundle)
        let copyPiece = try XCTUnwrap(repo.pieces(in: copyID).first)
        let copyCounter = try XCTUnwrap(repo.counters(for: copyPiece.id).first)
        XCTAssertNotEqual(copyCounter.id, counter.id)
        XCTAssertEqual(copyCounter.value, 2)
        XCTAssertEqual(try repo.counterHistory(for: copyCounter.id).count, 3)
    }

    func testV6OnDiskMigrationKeepsRowsAndNotes() throws {
        let projectID = UUID(), pieceID = UUID(), eventID = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        do {
            let old = Schema([StoredProject.self, StoredPiece.self, StoredRowEvent.self, StoredStoreInfo.self,
                              StoredPatternDocument.self, StoredReferenceState.self, StoredShapingReminder.self,
                              StoredProgressCheckpoint.self, StoredLibraryEntry.self])
            let config = ModelConfiguration("RowCompanion", schema: old, url: url, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: old, configurations: [config]))
            context.insert(StoredStoreInfo(schemaVersion: 6, createdAt: date))
            context.insert(StoredProject(id: projectID, title: "Old", createdAt: date, updatedAt: date))
            context.insert(StoredPiece(id: pieceID, projectID: projectID, name: "Front", completedRows: 1,
                                       repeatLength: 8, notes: "Keep me"))
            context.insert(StoredRowEvent(id: eventID, pieceID: pieceID, sequence: 1, kind: .completeRow,
                                          before: 0, after: 1, createdAt: date, undoneEventID: nil))
            try context.save()
        }
        let repo = try RowRepository.open(storeURL: url)
        XCTAssertEqual(try repo.piece(pieceID).notes, "Keep me")
        XCTAssertEqual(try repo.history(for: pieceID).first?.id, eventID)
        XCTAssertTrue(try repo.counters(for: pieceID).isEmpty)
        _ = try repo.addCounter(to: pieceID, name: "Cable", unit: "rows")
        XCTAssertEqual(try repo.piece(pieceID).completedRows, 1)
    }
}
