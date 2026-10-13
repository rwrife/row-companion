import Foundation
import SwiftData

// MARK: - PDF annotations (issue #17)
//
// Annotations are *separate app records* keyed to the document id; the
// imported PDF bytes are never rewritten, so the source document stays
// byte-identical (its stored sha256 keeps proving that). Anchors reuse the
// top-left normalized media-box convention of `ReferenceState`, so zoom,
// rotation and relayout cannot invalidate them — viewers recompute pixels
// from the stored fractions every time.

@Model
public final class StoredDocumentAnnotation {
    @Attribute(.unique) public var id: UUID
    public var documentID: UUID
    public var kindRaw: String
    public var title: String
    public var pageIndex: Int
    public var rectX: Double
    public var rectY: Double
    public var rectWidth: Double
    public var rectHeight: Double
    public var createdAt: Date

    public init(_ annotation: DocumentAnnotation) {
        id = annotation.id; documentID = annotation.documentID; kindRaw = annotation.kind.rawValue
        title = annotation.title; pageIndex = annotation.pageIndex
        rectX = annotation.rect.x; rectY = annotation.rect.y
        rectWidth = annotation.rect.width; rectHeight = annotation.rect.height
        createdAt = annotation.createdAt
    }

    var record: DocumentAnnotation? {
        guard let kind = DocumentAnnotation.Kind(rawValue: kindRaw) else { return nil }
        return DocumentAnnotation(id: id, documentID: documentID, kind: kind, title: title,
                                  pageIndex: pageIndex,
                                  rect: NormalizedRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight),
                                  createdAt: createdAt)
    }
}

/// Repository surface for document annotations (issue #17).
///
/// Ownership decision made explicit for the acceptance criteria: annotations
/// belong to the **project document**, not a piece. Sleeves and fronts share
/// one chart; a highlight on chart row 12 is true for every piece working
/// from that page. Every mutation is one durable commit.
@MainActor
extension RowRepository {
    public func annotations(for documentID: UUID) throws -> [DocumentAnnotation] {
        let id = documentID
        return try context.fetch(FetchDescriptor<StoredDocumentAnnotation>(
            predicate: #Predicate { $0.documentID == id },
            sortBy: [SortDescriptor(\.pageIndex), SortDescriptor(\.createdAt)]
        )).compactMap(\.record)
    }

    func storedAnnotations(documentIDs: Set<UUID>) throws -> [StoredDocumentAnnotation] {
        guard !documentIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<StoredDocumentAnnotation>(
            predicate: #Predicate { documentIDs.contains($0.documentID) }
        ))
    }

    /// Add an annotation after pure validation against the document's actual
    /// page count. An annotation for an unknown document is refused; a page
    /// index beyond the document clamps down (shrunk/replaced stores fail
    /// soft into range rather than pointing at nothing).
    @discardableResult
    public func addAnnotation(to documentID: UUID, kind: DocumentAnnotation.Kind,
                              title: String, pageIndex: Int, rect: NormalizedRect) throws -> DocumentAnnotation {
        guard let document = try storedDocument(documentID) else {
            throw RowRepositoryError.documentNotFound(documentID)
        }
        let page = ViewportClamp.clamp(pageIndex: pageIndex, pageCount: document.pageCount)
        let candidate = DocumentAnnotation(documentID: documentID, kind: kind,
                                           title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                           pageIndex: page, rect: ViewportClamp.clamp(rect))
        guard AnnotationRules.valid(candidate, pageCount: document.pageCount) else {
            throw RowRepositoryError.annotationInvalid
        }
        context.insert(StoredDocumentAnnotation(candidate))
        try commit()
        return candidate
    }

    /// Remove one annotation. Missing ids are a no-op (mirrors reminders).
    public func removeAnnotation(id annotationID: UUID) throws {
        let id = annotationID
        let descriptor = FetchDescriptor<StoredDocumentAnnotation>(predicate: #Predicate { $0.id == id })
        guard let stored = try context.fetch(descriptor).first else { return }
        context.delete(stored)
        try commit()
    }

    /// Rename a bookmark/highlight label in place, keeping its anchor.
    public func renameAnnotation(id annotationID: UUID, title: String) throws {
        let id = annotationID
        guard let stored = try context.fetch(FetchDescriptor<StoredDocumentAnnotation>(
            predicate: #Predicate { $0.id == id })).first else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 500 else { throw RowRepositoryError.annotationInvalid }
        stored.title = clean
        try commit()
    }
}
