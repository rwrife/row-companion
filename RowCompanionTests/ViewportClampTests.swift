import XCTest
@testable import RowCompanion

/// Pure-rule tests for the clamping and coordinate conventions documented in
/// `ReferenceState.swift` (top-left origin normalized rect, clamp on restore).
final class ViewportClampTests: XCTestCase {
    func testRectClampKeepsEverythingInsideUnitSquare() {
        let hostile = NormalizedRect(x: -0.5, y: 1.7, width: 3, height: -2)
        let clamped = ViewportClamp.clamp(hostile)
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 1 + 0.0000001)
        XCTAssertLessThanOrEqual(clamped.y + clamped.height, 1 + 0.0000001)
        XCTAssertGreaterThanOrEqual(clamped.width, ViewportClamp.minimumFraction)
        XCTAssertGreaterThanOrEqual(clamped.height, ViewportClamp.minimumFraction)
    }

    func testRectClampShiftsOverflowingOriginsInward() {
        let rect = NormalizedRect(x: 0.8, y: 0.9, width: 0.5, height: 0.5)
        let clamped = ViewportClamp.clamp(rect)
        XCTAssertEqual(clamped.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 0.5, accuracy: 1e-9)
    }

    func testRectClampIsIdempotentOnValidRects() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3)
        XCTAssertEqual(ViewportClamp.clamp(rect), rect)
    }

    func testPageIndexClampAgainstPageCount() {
        XCTAssertEqual(ViewportClamp.clamp(pageIndex: 999, pageCount: 3), 2)
        XCTAssertEqual(ViewportClamp.clamp(pageIndex: -4, pageCount: 3), 0)
        XCTAssertEqual(ViewportClamp.clamp(pageIndex: 7, pageCount: 0), 0)
        XCTAssertEqual(ViewportClamp.clamp(pageIndex: 1, pageCount: 10), 1)
    }

    func testGuideClamp() {
        XCTAssertEqual(ViewportClamp.clamp(guideY: 1.4), 1)
        XCTAssertEqual(ViewportClamp.clamp(guideY: -0.2), 0)
        XCTAssertEqual(ViewportClamp.clamp(guideY: 0.5), 0.5)
        XCTAssertNil(ViewportClamp.clamp(guideY: nil))
    }

    func testWholeStateClampShrinksStalePageOnSmallerDocument() {
        let state = ReferenceState(
            pieceID: UUID(),
            documentID: UUID(),
            pageIndex: 120,
            visibleRect: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            guideY: 2
        )
        let clamped = ViewportClamp.clamp(state, pageCount: 50)
        XCTAssertEqual(clamped.pageIndex, 49)
        XCTAssertEqual(clamped.guideY, 1)
    }

    // MARK: - PDFKit coordinate conversion

    private let pageSize = CGSize(width: 400, height: 600)

    func testPageRectUsesTopLeftOriginConvention() {
        // Top strip of the page in stored (top-left) space.
        let stored = NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)
        let pageRect = PDFCoordinateSpace.pageRect(for: stored, pageSize: pageSize)
        XCTAssertEqual(pageRect.minY, 300, accuracy: 1e-9, "top-left stored y=0..0.5 maps to the top half in bottom-left page space")
        XCTAssertEqual(pageRect.height, 300, accuracy: 1e-9)
    }

    func testRoundTripThroughPageSpaceIsStable() {
        for stored in [
            NormalizedRect.full,
            NormalizedRect(x: 0.25, y: 0.1, width: 0.5, height: 0.6),
            NormalizedRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05),
        ] {
            let pageRect = PDFCoordinateSpace.pageRect(for: stored, pageSize: pageSize)
            let back = PDFCoordinateSpace.normalizedRect(for: pageRect, pageSize: pageSize)
            XCTAssertEqual(back.x, stored.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, stored.y, accuracy: 1e-6)
            XCTAssertEqual(back.width, stored.width, accuracy: 1e-6)
            XCTAssertEqual(back.height, stored.height, accuracy: 1e-6)
        }
    }

    func testDegeneratePageSizeFailsSafe() {
        XCTAssertEqual(
            PDFCoordinateSpace.normalizedRect(for: CGRect(x: 0, y: 0, width: 50, height: 50), pageSize: .zero),
            .full
        )
        XCTAssertEqual(PDFCoordinateSpace.pageRect(for: .full, pageSize: .zero), .zero)
    }

    func testNormalizedConversionClampsHostilePageRects() {
        // A rect bigger than the page (e.g. mid-zoom overscroll) normalizes
        // back through the clamps instead of poisoning the store.
        let huge = CGRect(x: -100, y: -100, width: 2000, height: 2000)
        let normalized = PDFCoordinateSpace.normalizedRect(for: huge, pageSize: pageSize)
        XCTAssertGreaterThanOrEqual(normalized.x, 0)
        XCTAssertLessThanOrEqual(normalized.x + normalized.width, 1.0000001)
    }
}
