import Foundation
import SwiftData

// MARK: - Pattern document + reference-state storage (issue #3)
//
// `StoredPatternDocument` mirrors PLAN.md `PatternDocument(id, projectID,
// relativePath, sha256, pageCount)`. Only *app-owned relative paths* are ever
// stored — the user's original filename and source URL are never persisted
// (privacy contract: "never trusted source filenames"). `StoredReferenceState`
// mirrors `ReferenceState(pieceID, documentID, pageIndex, normalizedVisibleRect,
// guideY)`; the rect components are stored as plain Doubles so the on-disk
// shape stays simple and clamping lives entirely in the pure `ViewportClamp`
// domain rules, not in storage code.

@Model
public final class StoredPatternDocument {
    @Attribute(.unique) public var id: UUID
    public var projectID: UUID
    /// Relative to the store directory, e.g. `documents/<uuid>.pdf`. Generated
    /// filename only; never the user's original name.
    public var relativePath: String
    public var sha256: String
    public var pageCount: Int

    public init(id: UUID, projectID: UUID, relativePath: String, sha256: String, pageCount: Int) {
        self.id = id
        self.projectID = projectID
        self.relativePath = relativePath
        self.sha256 = sha256
        self.pageCount = pageCount
    }

    var record: PatternDocumentRecord {
        PatternDocumentRecord(id: id, projectID: projectID, relativePath: relativePath, sha256: sha256, pageCount: pageCount)
    }
}

@Model
public final class StoredReferenceState {
    @Attribute(.unique) public var pieceID: UUID
    public var documentID: UUID?
    public var pageIndex: Int
    public var rectX: Double
    public var rectY: Double
    public var rectWidth: Double
    public var rectHeight: Double
    public var guideY: Double?

    public init(
        pieceID: UUID,
        documentID: UUID?,
        pageIndex: Int,
        visibleRect: NormalizedRect,
        guideY: Double?
    ) {
        self.pieceID = pieceID
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.rectX = visibleRect.x
        self.rectY = visibleRect.y
        self.rectWidth = visibleRect.width
        self.rectHeight = visibleRect.height
        self.guideY = guideY
    }

    var visibleRect: NormalizedRect {
        NormalizedRect(x: rectX, y: rectY, width: rectWidth, height: rectHeight)
    }

    /// Value record form. A nil `documentID` means "no reference document" —
    /// text-only pieces legitimately have no viewer at all.
    var record: ReferenceState {
        ReferenceState(pieceID: pieceID, documentID: documentID, pageIndex: pageIndex, visibleRect: visibleRect, guideY: guideY)
    }
}
