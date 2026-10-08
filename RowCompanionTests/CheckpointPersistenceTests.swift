import XCTest
import SwiftData
@testable import RowCompanion

@MainActor
final class CheckpointPersistenceTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-checkpoint-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("rowcompanion.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCheckpointRoundTripAndCorrectionPreservesHistory() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Cardigan")
        let front = try repo.addPiece(to: project.id, name: "Front", repeatLength: 8)
        let back = try repo.addPiece(to: project.id, name: "Back")
        for _ in 0..<8 { try repo.apply(.completeRow, to: front.id) }
        let checkpoint = try repo.addCheckpoint(to: front.id, name: "Finished ribbing")
        XCTAssertEqual(checkpoint.completedRows, 8)
        XCTAssertEqual(checkpoint.repeatLength, 8)
        XCTAssertTrue(try repo.checkpoints(for: back.id).isEmpty)
        try repo.apply(.setRepeatLength(4), to: front.id)
        try repo.apply(.completeRow, to: front.id)
        XCTAssertThrowsError(try repo.restoreCheckpoint(checkpoint.id, confirmed: false))
        XCTAssertEqual(try repo.piece(front.id).completedRows, 9)
        let correction = try repo.restoreCheckpoint(checkpoint.id, confirmed: true)
        XCTAssertEqual(correction.kind, .correction)
        XCTAssertEqual(correction.before, 9)
        XCTAssertEqual(correction.after, 8)
        XCTAssertEqual(try repo.piece(front.id).repeatLength, 4, "restore changes recorded count, not repeat configuration")
        XCTAssertEqual(try repo.history(for: front.id).count, 11, "history is append-only")
        XCTAssertThrowsError(try repo.restoreCheckpoint(checkpoint.id, confirmed: true)) { error in
            XCTAssertEqual(error as? RowDomainError, .correctionUnchanged)
        }
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.checkpoints(for: front.id).map(\.name), ["Finished ribbing"])
        XCTAssertEqual(try relaunched.history(for: front.id).last?.kind, .correction)
        XCTAssertEqual(try relaunched.piece(back.id).completedRows, 0)
    }

    func testDuplicateNamesAndFaultedSaveAreNotDurable() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Test")
        let piece = try repo.addPiece(to: project.id, name: "Front")
        _ = try repo.addCheckpoint(to: piece.id, name: "Ribbing")
        XCTAssertThrowsError(try repo.addCheckpoint(to: piece.id, name: " ribbing "))
        struct Injected: Error {}
        repo.testSaveFault = { throw Injected() }
        XCTAssertThrowsError(try repo.addCheckpoint(to: piece.id, name: "Sleeves"))
        repo.testSaveFault = nil
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.checkpoints(for: piece.id).map(\.name), ["Ribbing"])
    }

    func testCorrectionSaveFaultLeavesCountAndHistoryUntouched() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Test")
        let piece = try repo.addPiece(to: project.id, name: "Front", startingRows: 3)
        let checkpoint = try repo.addCheckpoint(to: piece.id, name: "Start")
        try repo.apply(.completeRow, to: piece.id)
        struct Injected: Error {}
        repo.testSaveFault = { throw Injected() }
        XCTAssertThrowsError(try repo.restoreCheckpoint(checkpoint.id, confirmed: true))
        repo.testSaveFault = nil
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.piece(piece.id).completedRows, 4)
        XCTAssertEqual(try relaunched.history(for: piece.id).count, 1)
    }

    func testBackupRoundTripPreservesCheckpointsAndHistory() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Checkpoint backup")
        let piece = try repo.addPiece(to: project.id, name: "Body", repeatLength: 8)
        try repo.apply(.completeRow, to: piece.id)
        let checkpoint = try repo.addCheckpoint(to: piece.id, name: "Ribbing")
        try repo.apply(.setRepeatLength(4), to: piece.id)
        try repo.apply(.completeRow, to: piece.id)
        let service = BackupService(repository: repo)
        let folder = tempDir.appendingPathComponent("backup")
        try service.exportFullBackup(for: project.id, to: folder)
        let newProject = try service.restore(from: folder)
        let restoredPiece = try XCTUnwrap(repo.pieces(in: newProject).first)
        let restoredCheckpoint = try XCTUnwrap(repo.checkpoints(for: restoredPiece.id).first)
        XCTAssertNotEqual(restoredCheckpoint.id, checkpoint.id)
        XCTAssertNotEqual(restoredPiece.id, piece.id)
        XCTAssertEqual(restoredCheckpoint.completedRows, 1)
        XCTAssertEqual(restoredCheckpoint.repeatLength, 8)
        XCTAssertEqual(restoredPiece.repeatLength, 4)
        XCTAssertEqual(try repo.history(for: restoredPiece.id).map(\.kind), [.completeRow, .repeatLengthChange, .completeRow])
        try repo.restoreCheckpoint(restoredCheckpoint.id, confirmed: true)
        XCTAssertEqual(try repo.piece(restoredPiece.id).completedRows, 1)
        XCTAssertEqual(try repo.piece(piece.id).completedRows, 2)
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.checkpoints(for: restoredPiece.id).map(\.name), ["Ribbing"])
        XCTAssertEqual(try relaunched.history(for: restoredPiece.id).last?.kind, .correction)
    }

    func testLegacyBackupDecodesWithoutCheckpointsAndNewExportsRequireV2() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Legacy")
        let data = try BackupService(repository: repo).exportProgress(for: project.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(BackupFormat.Manifest.self, from: data).schemaVersion, 2)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "checkpoints")
        legacy["schemaVersion"] = 1
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertTrue(try decoder.decode(BackupFormat.Manifest.self, from: legacyData).checkpoints.isEmpty)
    }

    func testMigratesOlderStoreAndDeletesCheckpointsWithProject() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Test")
        let piece = try repo.addPiece(to: project.id, name: "Front")
        let context = ModelContext(repo.container)
        let info = try XCTUnwrap(context.fetch(FetchDescriptor<StoredStoreInfo>()).first)
        info.schemaVersion = 4
        try context.save()
        let relaunched = try RowRepository.open(storeURL: storeURL)
        let checkpoint = try relaunched.addCheckpoint(to: piece.id, name: "Start")
        XCTAssertEqual(try relaunched.checkpoints(for: piece.id).count, 1)
        try relaunched.deleteProject(project.id, confirmed: true)
        XCTAssertTrue(try relaunched.checkpoints(for: piece.id).isEmpty)
        XCTAssertThrowsError(try relaunched.restoreCheckpoint(checkpoint.id, confirmed: true))
    }
}
