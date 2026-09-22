import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure conversion between the stored **top-left origin normalized** viewport
/// (see `ReferenceState.swift`) and PDFKit's **bottom-left page space** for a
/// page of known size. Kept free of PDFKit/SwiftUI so the conversion is
/// unit-testable without any view and outside Apple-only frameworks
/// (issue #3: document per-piece viewport coordinate/clamping behavior).
public enum PDFCoordinateSpace {
    /// Stored normalized rect (top-left origin) -> PDFKit page-space rect.
    public static func pageRect(for rect: NormalizedRect, pageSize: CGSize) -> CGRect {
        guard pageSize.width > 0, pageSize.height > 0 else { return .zero }
        let w = rect.width * pageSize.width
        let h = rect.height * pageSize.height
        let x = rect.x * pageSize.width
        // Top-left y -> bottom-left origin for the *bottom* of the rect.
        let y = (1 - rect.y - rect.height) * pageSize.height
        return CGRect(x: x, y: max(y, 0), width: w, height: h)
    }

    /// PDFKit page-space rect -> stored normalized rect (top-left origin).
    /// The result passes through `ViewportClamp`, so a mid-zoom overscroll
    /// rect can never poison the store.
    public static func normalizedRect(for visible: CGRect, pageSize: CGSize) -> NormalizedRect {
        guard pageSize.width > 0, pageSize.height > 0 else { return .full }
        let raw = NormalizedRect(
            x: Double(visible.minX / pageSize.width),
            y: Double(1 - visible.maxY / pageSize.height),
            width: Double(visible.width / pageSize.width),
            height: Double(visible.height / pageSize.height)
        )
        return ViewportClamp.clamp(raw)
    }

    /// The vertical position of the manual reading guide in page space given
    /// the normalized guide position and the page height.
    public static func guidePageY(guideY: Double, pageSize: CGSize) -> CGFloat {
        CGFloat(1 - min(max(guideY, 0), 1)) * pageSize.height
    }
}
