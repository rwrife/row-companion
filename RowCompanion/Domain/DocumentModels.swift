import Foundation

/// Plain value record for an imported pattern document (PLAN.md data model:
/// `PatternDocument(id, projectID, relativePath, sha256, pageCount)`).
/// Deliberately free of PDFKit/SwiftData/SwiftUI so it stays a testable value
/// type; `relativePath` is always an app-owned generated path.
public struct PatternDocumentRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    /// Relative to the app store directory, e.g. `documents/<uuid>.pdf`.
    public let relativePath: String
    /// Lowercase hex SHA-256 of the exact imported bytes.
    public let sha256: String
    public let pageCount: Int

    public init(id: UUID, projectID: UUID, relativePath: String, sha256: String, pageCount: Int) {
        self.id = id
        self.projectID = projectID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.pageCount = pageCount
    }
}
