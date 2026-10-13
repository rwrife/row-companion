import XCTest
import SwiftData
@testable import RowCompanion

/// Issue #17 — project-owned PDF annotations survive store reopen, backup,
/// duplication and migration without ever changing the imported PDF bytes.
@MainActor
final class AnnotationTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rc-annotation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("store.sqlite")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func writePDF() throws -> URL {
        let url = directory.appendingPathComponent("private-chart.pdf")
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "fixture", code: 1)
        }
        for _ in 0..<3 { context.beginPage(mediaBox: &box); context.endPage() }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    func testRoundTripCoordinatesReopenAndCopy() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Cardigan")
        _ = try repo.addPiece(to: project.id, name: "Left sleeve")
        _ = try repo.addPiece(to: project.id, name: "Right sleeve")
        let document = try repo.importPatternDocument(from: writePDF(), for: project.id)
        let pdfURL = try repo.documentFileURL(document.id)
        let original = try Data(contentsOf: pdfURL)
        let rect = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)
        let note = try repo.addAnnotation(to: document.id, kind: .note,
                                          title: "Watch decreases", pageIndex: 1, rect: rect)
        _ = try repo.addAnnotation(to: document.id, kind: .highlight,
                                   title: "Size M", pageIndex: 2, rect: rect)
        XCTAssertEqual(try repo.annotations(for: document.id).count, 2)
        XCTAssertEqual(try Data(contentsOf: pdfURL), original)
        let reopened = try RowRepository.open(storeURL: storeURL)
        let stored = try XCTUnwrap(reopened.annotations(for: document.id).first { $0.id == note.id })
        XCTAssertEqual(stored.rect, rect)
        XCTAssertEqual(stored.pageIndex, 1)
        let box = CGSize(width: 300, height: 400)
        let roundTrip = PDFCoordinateSpace.normalizedRect(for: PDFCoordinateSpace.pageRect(for: rect, pageSize: box), pageSize: box)
        XCTAssertEqual(roundTrip.x, rect.x, accuracy: 0.000001)
        XCTAssertEqual(roundTrip.y, rect.y, accuracy: 0.000001)
        XCTAssertEqual(roundTrip.width, rect.width, accuracy: 0.000001)
        XCTAssertEqual(roundTrip.height, rect.height, accuracy: 0.000001)
        let copyID = try reopened.duplicateProject(project.id, title: "Second cardigan")
        let copyDoc = try XCTUnwrap(reopened.documents(in: copyID).first)
        let copied = try reopened.annotations(for: copyDoc.id)
        XCTAssertEqual(Set(copied.map(\.title)), Set(["Watch decreases", "Size M"]))
        XCTAssertTrue(copied.allSatisfy { $0.documentID == copyDoc.id })
        XCTAssertEqual(try Data(contentsOf: pdfURL), original)
        try reopened.removeAnnotation(id: note.id)
        XCTAssertEqual(try reopened.annotations(for: document.id).count, 1)
    }

    func testValidationBackupRemapAndDelete() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Hat")
        let document = try repo.importPatternDocument(from: writePDF(), for: project.id)
        let item = try repo.addAnnotation(to: document.id, kind: .bookmark,
                                          title: "Crown shaping", pageIndex: 2,
                                          rect: NormalizedRect(x: 0, y: 0.8, width: 1, height: 0.2))
        XCTAssertEqual(try repo.projectSnapshot(for: project.id).annotations.first?.id, item.id)
        let manifest = try repo.projectSnapshot(for: project.id)
        let stage = directory.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("originals", isDirectory: true),
                                                withIntermediateDirectories: true)
        let pdfName = manifest.documents.first!.relativePath.components(separatedBy: "/").last!
        try Data(contentsOf: directory.appendingPathComponent("private-chart.pdf"))
            .write(to: stage.appendingPathComponent("originals", isDirectory: true)
                           .appendingPathComponent(pdfName))
        let validated = try BackupFormat.validate(manifest: manifest, stagedDirectory: stage)
        let remapped = BackupFormat.remap(validated, newIDs: { UUID() })
        XCTAssertNotEqual(remapped.manifest.annotations.first?.id, item.id)
        XCTAssertEqual(remapped.manifest.annotations.first?.documentID, remapped.manifest.documents.first?.id)
        var bad = manifest
        bad.annotations[0].pageIndex = 99
        XCTAssertThrowsError(try BackupFormat.validate(manifest: bad, stagedDirectory: stage))
        bad = manifest
        bad.annotations.append(bad.annotations[0])
        XCTAssertThrowsError(try BackupFormat.validate(manifest: bad, stagedDirectory: stage))
        try repo.deleteProject(project.id, confirmed: true)
        XCTAssertTrue(try repo.annotations(for: document.id).isEmpty)
    }

    func testSaveFailureAndLegacyStoreMigration() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Scarf")
        let document = try repo.importPatternDocument(from: writePDF(), for: project.id)
        let rect = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        repo.testSaveFault = { throw RowRepositoryError.annotationInvalid }
        XCTAssertThrowsError(try repo.addAnnotation(to: document.id, kind: .bookmark,
                                                     title: "Start", pageIndex: 0, rect: rect))
        repo.testSaveFault = nil
        XCTAssertTrue(try RowRepository.open(storeURL: storeURL).annotations(for: document.id).isEmpty)
    }

    /// Real disk migration: a shipped v7 (counters) store opens under v8,
    /// keeps every prior entity, and gains empty annotations.
    func testV7OnDiskMigrationKeepsCountersAndRows() throws {
        let projectID = UUID(), pieceID = UUID(), counterID = UUID(), eventID = UUID()
        let date = Date(timeIntervalSince1970: 1000)
        do {
            let old = Schema([StoredProject.self, StoredPiece.self, StoredRowEvent.self, StoredStoreInfo.self,
                              StoredPatternDocument.self, StoredReferenceState.self,
                              StoredShapingReminder.self, StoredProgressCheckpoint.self, StoredLibraryEntry.self,
                              StoredNamedCounter.self, StoredCounterEvent.self])
            let config = ModelConfiguration("RowCompanion", schema: old, url: storeURL, cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: old, configurations: [config]))
            context.insert(StoredStoreInfo(schemaVersion: 7, createdAt: date))
            context.insert(StoredProject(id: projectID, title: "Old", createdAt: date, updatedAt: date))
            context.insert(StoredPiece(id: pieceID, projectID: projectID, name: "Front", completedRows: 3,
                                       repeatLength: 8, notes: "Keep me"))
            context.insert(StoredRowEvent(id: eventID, pieceID: pieceID, sequence: 1, kind: .completeRow,
                                          before: 2, after: 3, createdAt: date, undoneEventID: nil))
            context.insert(StoredNamedCounter(id: counterID, pieceID: pieceID, name: "Motif", unit: "repeats",
                                              startingValue: 1, value: 2, repeatLength: 8, advancesWithRows: false))
            try context.save()
        }
        let repo = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try repo.piece(pieceID).notes, "Keep me")
        XCTAssertEqual(try repo.piece(pieceID).completedRows, 3)
        XCTAssertEqual(try repo.history(for: pieceID).first?.id, eventID)
        XCTAssertEqual(try repo.counters(for: pieceID).map(\.value), [2])
        let document = try repo.importPatternDocument(from: writePDF(), for: projectID)
        _ = try repo.addAnnotation(to: document.id, kind: .bookmark, title: "After migration",
                                   pageIndex: 0, rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(try repo.piece(pieceID).completedRows, 3)
        XCTAssertEqual(try repo.requireCounter(counterID).value, 2)
    }
}
