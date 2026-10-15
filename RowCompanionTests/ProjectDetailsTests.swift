import XCTest
import SwiftData
@testable import RowCompanion

@MainActor
final class ProjectDetailsTests: XCTestCase {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-details-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.sqlite")
    }

    func testDetailsSurviveReopenDuplicateAndBackupRestore() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Hat").id
        let piece = try repo.addPiece(to: project, name: "Crown").id
        let details = ProjectDetails(material: "Wool", colorway: "Blue", selectedSize: "Medium",
            toolSizeMM: 4.5, gaugeStitchesPer10CM: 21.5, gaugeRowsPer10CM: nil, measurementMM: 560)
        try repo.setDetails(details, forProject: project)
        try repo.setDetails(ProjectDetails(toolSizeMM: 3.75), forPiece: piece)

        let reopened = try RowRepository.open(storeURL: url)
        XCTAssertEqual(try reopened.details(forProject: project), details)
        XCTAssertEqual(try reopened.effectiveDetails(forPiece: piece).toolSizeMM, 3.75)
        XCTAssertEqual(try reopened.effectiveDetails(forPiece: piece).material, "Wool")

        let duplicate = try reopened.duplicateProject(project, title: "Copy")
        let copiedPiece = try XCTUnwrap(reopened.pieces(in: duplicate).first)
        XCTAssertEqual(try reopened.details(forProject: duplicate), details)
        XCTAssertEqual(try reopened.effectiveDetails(forPiece: copiedPiece.id).toolSizeMM, 3.75)

        let data = try BackupService(repository: reopened).exportProgress(for: project)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupFormat.Manifest.self, from: data)
        let staged = url.deletingLastPathComponent().appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let validated = try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)
        let restored = try reopened.insertRestoredProject(BackupFormat.remap(validated, newIDs: { UUID() }))
        XCTAssertEqual(try reopened.details(forProject: restored), details)
        let restoredPiece = try XCTUnwrap(reopened.pieces(in: restored).first)
        XCTAssertEqual(try reopened.effectiveDetails(forPiece: restoredPiece.id).toolSizeMM, 3.75)
        XCTAssertEqual(try reopened.details(forProject: restored).measurementMM, 560)
        XCTAssertEqual(try reopened.details(forProject: restored).material, "Wool")
    }

    func testInvalidDetailsRejectWithoutMutationAndUnitsDoNotChangeStoredValues() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Hat").id
        var details = ProjectDetails(measurementMM: 254)
        try repo.setDetails(details, forProject: project)
        XCTAssertEqual(ProjectDetails.inches(fromMM: 254), 10, accuracy: 0.000001)
        XCTAssertEqual(ProjectDetails.mm(fromInches: 10), 254, accuracy: 0.000001)
        details.toolSizeMM = .nan
        XCTAssertThrowsError(try repo.setDetails(details, forProject: project))
        XCTAssertEqual(try repo.details(forProject: project), ProjectDetails(measurementMM: 254))
        let restored = try RowRepository.open(storeURL: url)
        XCTAssertEqual(try restored.details(forProject: project).measurementMM, 254)
        XCTAssertNil(try restored.details(forProject: project).toolSizeMM)
    }

    func testV7StoreMigratesToEmptyDetails() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID(), date = Date(timeIntervalSince1970: 1000)
        let old = Schema([StoredProject.self, StoredPiece.self, StoredRowEvent.self, StoredStoreInfo.self,
            StoredPatternDocument.self, StoredReferenceState.self, StoredShapingReminder.self,
            StoredProgressCheckpoint.self, StoredLibraryEntry.self, StoredNamedCounter.self, StoredCounterEvent.self])
        let config = ModelConfiguration("RowCompanion", schema: old, url: url, cloudKitDatabase: .none)
        let context = ModelContext(try ModelContainer(for: old, configurations: [config]))
        context.insert(StoredStoreInfo(schemaVersion: 7, createdAt: date))
        context.insert(StoredProject(id: id, title: "Legacy", createdAt: date, updatedAt: date))
        try context.save()

        let repo = try RowRepository.open(storeURL: url)
        XCTAssertEqual(try repo.details(forProject: id), ProjectDetails())
        XCTAssertEqual(try repo.projects().first?.title, "Legacy")
    }
}
