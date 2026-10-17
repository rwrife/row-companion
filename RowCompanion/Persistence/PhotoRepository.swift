import Foundation
import SwiftData
import CryptoKit
import UIKit

/// Additive photo storage for issue #20 (progress photos).
/// Kept local-first, zero-cloud, app-owned, and bounded:
/// - Max 10 MiB per photo; max 10 photos per project.
/// - PhotosPicker yields raw data; saved as `<uuid>.jpg` in `RowCompanionPhotos/`.
/// - StoredProgressPhoto entity holds ownerID (project or piece), description, and relativePath.
/// - Deleted when the project or photo is deleted.
@Model
public final class StoredProgressPhoto {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID
    public var relativePath: String
    public var photoDescription: String
    public var sha256: String
    public var fileSize: Int
    public var createdAt: Date

    public init(id: UUID, ownerID: UUID, relativePath: String, photoDescription: String, sha256: String, fileSize: Int, createdAt: Date) {
        self.id = id
        self.ownerID = ownerID
        self.relativePath = relativePath
        self.photoDescription = photoDescription
        self.sha256 = sha256
        self.fileSize = fileSize
        self.createdAt = createdAt
    }
}

public struct ProgressPhotoRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let ownerID: UUID
    public let relativePath: String
    public let photoDescription: String
    public let sha256: String
    public let fileSize: Int
    public let createdAt: Date

    public init(id: UUID, ownerID: UUID, relativePath: String, photoDescription: String, sha256: String, fileSize: Int, createdAt: Date) {
        self.id = id
        self.ownerID = ownerID
        self.relativePath = relativePath
        self.photoDescription = photoDescription
        self.sha256 = sha256
        self.fileSize = fileSize
        self.createdAt = createdAt
    }
}

public enum PhotoError: Error, Equatable, Sendable {
    case oversizedPhoto(byteCount: Int)
    case photoCapReached(count: Int)
    case unreadablePhoto
    case storageFailure(underlying: String)
    case photoNotFound(UUID)
    case ownerNotFound(UUID)

    public var userMessage: String {
        switch self {
        case .oversizedPhoto(let bytes):
            return "Photo is too large (\(ByteCount.Format.mebibytes(bytes))). The limit is \(ByteCount.Format.mebibytes(PhotoRepository.maximumPhotoBytes))."
        case .photoCapReached(let count):
            return "Project reached the maximum of \(count) progress photos."
        case .unreadablePhoto:
            return "This image data could not be saved."
        case .storageFailure:
            return "Could not save photo to disk. Check storage space."
        case .photoNotFound:
            return "Photo not found."
        case .ownerNotFound:
            return "Item not found."
        }
    }
}

@MainActor
public enum PhotoRepository {
    public static let maximumPhotoBytes = 10 * 1024 * 1024 // 10 MiB
    public static let maximumPhotosPerProject = 10
    public static let maximumDescriptionLength = 200

    public static func photosDirectory(storeURL: URL) -> URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("RowCompanionPhotos", isDirectory: true)
    }
}

@MainActor
extension RowRepository {
    public func photosDirectoryURL() -> URL {
        PhotoRepository.photosDirectory(storeURL: storeURL)
    }

    public func photoFileURL(_ relativePath: String) -> URL {
        // No caller may turn a corrupted store path into deletion outside
        // app-owned media. Invalid paths point at an absent safe leaf.
        let leaf = relativePath.components(separatedBy: "/").last ?? relativePath
        guard relativePath == "RowCompanionPhotos/\(leaf)",
              leaf.hasSuffix(".jpg"),
              UUID(uuidString: String(leaf.dropLast(4))) != nil else {
            return photosDirectoryURL().appendingPathComponent("invalid-photo-path")
        }
        return photosDirectoryURL().appendingPathComponent(leaf)
    }

    public func photos(forOwner ownerID: UUID) throws -> [ProgressPhotoRecord] {
        let id = ownerID
        let descriptor = FetchDescriptor<StoredProgressPhoto>(
            predicate: #Predicate { $0.ownerID == id },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor).map {
            ProgressPhotoRecord(id: $0.id, ownerID: $0.ownerID, relativePath: $0.relativePath,
                                photoDescription: $0.photoDescription, sha256: $0.sha256,
                                fileSize: $0.fileSize, createdAt: $0.createdAt)
        }
    }

    public func attachPhoto(data: Data, description: String, ownerID: UUID) throws -> ProgressPhotoRecord {
        guard try storedProject(ownerID) != nil else { throw PhotoError.ownerNotFound(ownerID) }
        guard description.count <= PhotoRepository.maximumDescriptionLength else { throw PhotoError.unreadablePhoto }
        guard data.count <= PhotoRepository.maximumPhotoBytes else {
            throw PhotoError.oversizedPhoto(byteCount: data.count)
        }
        guard !data.isEmpty, let image = UIImage(data: data),
              image.size.width > 0, image.size.height > 0,
              image.size.width * image.size.height <= 20_000_000 else {
            throw PhotoError.unreadablePhoto
        }
        let existing = try photos(forOwner: ownerID)
        guard existing.count < PhotoRepository.maximumPhotosPerProject else {
            throw PhotoError.photoCapReached(count: PhotoRepository.maximumPhotosPerProject)
        }
        let photoID = UUID()
        let filename = "\(photoID.uuidString).jpg"
        let relativePath = "RowCompanionPhotos/\(filename)"
        let targetURL = photosDirectoryURL().appendingPathComponent(filename)

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        let fm = FileManager.default
        let dir = photosDirectoryURL()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Store the user's original bytes untouched; the decode above is
        // validation only. The recorded hash and size describe exactly the
        // bytes written to disk.
        try data.write(to: targetURL, options: .withoutOverwriting)

        let record = StoredProgressPhoto(
            id: photoID, ownerID: ownerID, relativePath: relativePath,
            photoDescription: description, sha256: hex, fileSize: data.count, createdAt: Date()
        )
        context.insert(record)
        do {
            try commit()
        } catch {
            try? fm.removeItem(at: targetURL)
            throw error
        }
        return ProgressPhotoRecord(id: record.id, ownerID: record.ownerID, relativePath: record.relativePath,
                                   photoDescription: record.photoDescription, sha256: record.sha256,
                                   fileSize: record.fileSize, createdAt: record.createdAt)
    }

    public func photoFileBytes(_ photoID: UUID) throws -> Data {
        let id = photoID
        let descriptor = FetchDescriptor<StoredProgressPhoto>(predicate: #Predicate { $0.id == id })
        guard let photo = try context.fetch(descriptor).first else { throw PhotoError.photoNotFound(photoID) }
        let url = photoFileURL(photo.relativePath)
        guard let data = try? Data(contentsOf: url), data.count == photo.fileSize,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == photo.sha256 else {
            throw PhotoError.unreadablePhoto
        }
        return data
    }

    public func setPhotoDescription(_ text: String, for id: UUID) throws {
        let photoID = id
        let descriptor = FetchDescriptor<StoredProgressPhoto>(predicate: #Predicate { $0.id == photoID })
        guard let stored = try context.fetch(descriptor).first else { throw PhotoError.photoNotFound(id) }
        guard text.count <= PhotoRepository.maximumDescriptionLength else { throw PhotoError.unreadablePhoto }
        stored.photoDescription = text
        try commit()
    }

    public func removePhoto(_ id: UUID) throws {
        let photoID = id
        let descriptor = FetchDescriptor<StoredProgressPhoto>(predicate: #Predicate { $0.id == photoID })
        guard let stored = try context.fetch(descriptor).first else { return }
        let fileURL = photoFileURL(stored.relativePath)
        context.delete(stored)
        try commit()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func storedPhotos(ownerIDs: Set<UUID>) throws -> [StoredProgressPhoto] {
        guard !ownerIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<StoredProgressPhoto>(predicate: #Predicate {
            ownerIDs.contains($0.ownerID)
        }))
    }
}
