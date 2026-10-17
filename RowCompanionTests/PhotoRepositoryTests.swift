import XCTest
import SwiftData
import UIKit
@testable import RowCompanion

@MainActor
final class PhotoRepositoryTests: XCTestCase {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-photos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("store.sqlite")
    }

    private func sampleJPEGData(color: UIColor = .red, size: CGSize = CGSize(width: 10, height: 10)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    func testPhotoPersistenceDuplicateAndDelete() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Sweater").id
        let data = sampleJPEGData()
        let attached = try repo.attachPhoto(data: data, description: "Collar cast-on", ownerID: project)
        XCTAssertEqual(attached.photoDescription, "Collar cast-on")
        XCTAssertEqual(attached.ownerID, project)
        let fileURL = repo.photoFileURL(attached.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Open fresh repo, verify persistence
        let reopened = try RowRepository.open(storeURL: url)
        let list = try reopened.photos(forOwner: project)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, attached.id)
        XCTAssertEqual(try reopened.photoFileBytes(attached.id), data)

        // Duplicate with progress preserves photo with new file path
        let duplicateWithProgress = try reopened.duplicateProject(project, title: "Sweater v2", copyProgress: true)
        let dupPhotos = try reopened.photos(forOwner: duplicateWithProgress)
        XCTAssertEqual(dupPhotos.count, 1)
        XCTAssertNotEqual(dupPhotos.first?.id, attached.id)
        XCTAssertNotEqual(dupPhotos.first?.relativePath, attached.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.photoFileURL(try XCTUnwrap(dupPhotos.first).relativePath).path))

        // Duplicate without progress excludes photos
        let duplicateClean = try reopened.duplicateProject(project, title: "Sweater Clean", copyProgress: false)
        XCTAssertTrue(try reopened.photos(forOwner: duplicateClean).isEmpty)

        // Deleting project removes photo record and photo file from storage
        try BackupRepositoryTests_deleteProject(repo: reopened, projectID: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(try reopened.photos(forOwner: project).isEmpty)
    }

    private func BackupRepositoryTests_deleteProject(repo: RowRepository, projectID: UUID) throws {
        try repo.deleteProject(projectID, confirmed: true)
    }

    func testPhotoBounds() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Hat").id
        let data = sampleJPEGData()

        // 10 photos is the cap
        for i in 1...10 {
            _ = try repo.attachPhoto(data: data, description: "Photo \(i)", ownerID: project)
        }
        XCTAssertThrowsError(try repo.attachPhoto(data: data, description: "11th", ownerID: project)) { error in
            guard case PhotoError.photoCapReached = error else { return XCTFail("expected cap reached, got \(error)") }
        }

        // Empty data refused
        XCTAssertThrowsError(try repo.attachPhoto(data: Data(), description: "", ownerID: project))

        // Description bounded at 200
        let longDesc = String(repeating: "a", count: 201)
        XCTAssertThrowsError(try repo.attachPhoto(data: data, description: longDesc, ownerID: project))
    }

    func testFullBackupRestoresPhotos() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Scarf").id
        let data = sampleJPEGData()
        let attached = try repo.attachPhoto(data: data, description: "Swatch", ownerID: project)

        let backupDir = url.deletingLastPathComponent().appendingPathComponent("backup-export", isDirectory: true)
        let service = BackupService(repository: repo)
        try service.exportFullBackup(for: project, to: backupDir)

        let restoredProjectID = try service.restore(from: backupDir)
        let restoredPhotos = try repo.photos(forOwner: restoredProjectID)
        XCTAssertEqual(restoredPhotos.count, 1)
        XCTAssertEqual(restoredPhotos.first?.photoDescription, "Swatch")
        XCTAssertNotEqual(restoredPhotos.first?.id, attached.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.photoFileURL(try XCTUnwrap(restoredPhotos.first).relativePath).path))
    }

    func testMissingPhotoRefusesFullExport() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Socks").id
        let attached = try repo.attachPhoto(data: sampleJPEGData(), description: "Heel", ownerID: project)
        try FileManager.default.removeItem(at: repo.photoFileURL(attached.relativePath))

        let backupDir = url.deletingLastPathComponent().appendingPathComponent("bad-backup", isDirectory: true)
        let service = BackupService(repository: repo)
        XCTAssertThrowsError(try service.exportFullBackup(for: project, to: backupDir))
    }

    func testLegacyPhotoFreeManifestRestores() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repo = try RowRepository(storeURL: url)
        let project = try repo.createProject(title: "Blanket").id

        let progressData = try BackupService(repository: repo).exportProgress(for: project)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupFormat.Manifest.self, from: progressData)
        XCTAssertTrue(manifest.photos.isEmpty)

        let staged = url.deletingLastPathComponent().appendingPathComponent("staged-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let validated = try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)
        let restoredID = try repo.insertRestoredProject(BackupFormat.remap(validated, newIDs: { UUID() }))
        XCTAssertTrue(try repo.photos(forOwner: restoredID).isEmpty)
    }
}
