import Foundation

// MARK: - Per-piece document reference state (PLAN.md data model)
//
// Coordinate convention (documented per issue #3 acceptance):
// `NormalizedRect` uses a **top-left origin** UI convention (y grows downward),
// with every component in `0...1` relative to the page's media box. This is
// deliberately view-oriented rather than PDFKit's bottom-left page space; the
// conversion to/from PDFKit coordinates happens once at the viewer edge and is
// covered by the import/viewer tests. Storing *normalized* values (never pixel
// offsets) keeps a saved viewport meaningful across rotation, size-class
// changes, and future layout rearrangement — restoring re-applies page, then
// zoom/location after view layout, and clamps everything back into range.

/// A rectangle normalized to the unit square (top-left origin).
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Whole page visible.
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

/// Where the reader left off on a piece's reference document (PLAN.md
/// `ReferenceState`). `guideY` is the manual horizontal reading guide,
/// normalized to the viewer height; it is pure view state and can never
/// influence row arithmetic (no path from this type to `RowAction`).
public struct ReferenceState: Codable, Equatable, Sendable {
    public let pieceID: UUID
    public var documentID: UUID?
    public var pageIndex: Int
    public var visibleRect: NormalizedRect
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
        self.visibleRect = visibleRect
        self.guideY = guideY
    }
}

/// Pure clamping rules applied whenever a stored viewport is read back
/// ("clamp on restore", PLAN.md). Out-of-range persisted values (tampered or
/// stale stores, shrunk documents) can never produce an impossible view.
public enum ViewportClamp {
    /// Smallest usable visible fraction; degenerate rectangles are grown back.
    public static let minimumFraction = 0.05

    public static func clamp(_ rect: NormalizedRect) -> NormalizedRect {
        let w = min(max(rect.width, minimumFraction), 1)
        let h = min(max(rect.height, minimumFraction), 1)
        var x = rect.x
        var y = rect.y
        // Clamp origin so the rectangle stays inside the unit square.
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
        // A negative-size input could already have pushed x/y below 0 via the
        // width clamp above; final non-negative pin.
        x = max(x, 0)
        y = max(y, 0)
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }

    public static func clamp(pageIndex: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return min(max(pageIndex, 0), pageCount - 1)
    }

    public static func clamp(guideY: Double?) -> Double? {
        guideY.map { min(max($0, 0), 1) }
    }

    /// Clamp a full reference state against a document's actual page count.
    public static func clamp(_ state: ReferenceState, pageCount: Int) -> ReferenceState {
        ReferenceState(
            pieceID: state.pieceID,
            documentID: state.documentID,
            pageIndex: clamp(pageIndex: state.pageIndex, pageCount: pageCount),
            visibleRect: clamp(state.visibleRect),
            guideY: clamp(guideY: state.guideY)
        )
    }
}
