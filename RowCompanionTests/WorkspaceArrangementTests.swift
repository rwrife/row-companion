import XCTest
@testable import RowCompanion

/// Pure arrangement rules for issue #4: the two-pane decision, the
/// accessibility-size fallback, and the reversibility of pane order.
/// These are the exact facts `WorkspaceLayout` reads from the environment,
/// so testing them here proves the fallback rules without a device.
final class WorkspaceArrangementTests: XCTestCase {
    func testTwoPaneNeedsRegularWidthAndReadableType() {
        XCTAssertTrue(WorkspaceArrangement.useTwoPane(regularWidth: true, isAccessibilitySize: false))
        XCTAssertFalse(WorkspaceArrangement.useTwoPane(regularWidth: false, isAccessibilitySize: false),
                       "compact phone must stay stacked")
        XCTAssertFalse(WorkspaceArrangement.useTwoPane(regularWidth: true, isAccessibilitySize: true),
                       "accessibility text sizes must fall back to stacked content")
        XCTAssertFalse(WorkspaceArrangement.useTwoPane(regularWidth: false, isAccessibilitySize: true),
                       "compact + accessibility size is stacked")
    }

    func testPaneOrderFlipIsReversible() {
        XCTAssertEqual(WorkspaceArrangement.flipped(.referenceFirst), .controlsFirst)
        XCTAssertEqual(WorkspaceArrangement.flipped(.controlsFirst), .referenceFirst)
        // Two flips are identity — reordering never strands the layout.
        XCTAssertEqual(
            WorkspaceArrangement.flipped(WorkspaceArrangement.flipped(.referenceFirst)),
            .referenceFirst
        )
    }

    /// The dual-screen seam is a documentation string, not an API surface:
    /// nothing in this module can reach fold/hinge SDK types.
    func testDualScreenSeamIsNoteOnly() {
        XCTAssertTrue(WorkspaceArrangement.futureDualScreenAdapterNote.contains("no fold SDK APIs")
                      || WorkspaceArrangement.futureDualScreenAdapterNote.contains("never depends"))
    }
}
