import Foundation

/// Project-owned annotations on an app-owned document. Source PDF bytes never change.
/// Coordinates use the same top-left normalized media-box convention as ReferenceState.
public struct DocumentAnnotation: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case bookmark, highlight, note }
    public let id: UUID
    public let documentID: UUID
    public let kind: Kind
    public let title: String
    public let pageIndex: Int
    public let rect: NormalizedRect
    public let createdAt: Date

    public init(id: UUID = UUID(), documentID: UUID, kind: Kind, title: String,
                pageIndex: Int, rect: NormalizedRect, createdAt: Date = Date()) {
        self.id = id; self.documentID = documentID; self.kind = kind; self.title = title
        self.pageIndex = pageIndex; self.rect = rect; self.createdAt = createdAt
    }
}

public enum AnnotationRules {
    public static func valid(_ item: DocumentAnnotation, pageCount: Int) -> Bool {
        let r = item.rect
        return (0..<pageCount).contains(item.pageIndex)
            && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && item.title.count <= 500
            && [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite)
            && r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0
            && r.x + r.width <= 1 && r.y + r.height <= 1
    }
}
