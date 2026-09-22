import XCTest

/// Simulator journey for the resumable workspace (issue #3):
/// create project → add piece → complete rows → undo → relaunch keeps the
/// count. PDF fixture handling itself is exercised by the unit-test target's
/// real-disk integration tests (the fileImporter panel is system UI outside
/// this app's automation surface); this file proves the user-facing controls
/// drive the durable state owner and survive an app relaunch.
final class RowCompanionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        app = XCUIApplication()
        // Fresh container when the journey starts. The argument is removed
        // before any in-test relaunch so the *second* launch proves the
        // durable store actually survived.
        app.launchArguments = ["-rc-ui-tests-reset"]
    }

    private func createProject(_ title: String, piece: String, repeatLength: String?) {
        app.launch()
        XCTAssertTrue(app.staticTexts["workspace.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["workspace.status"].exists)

        app.buttons["menu.add"].tap()
        XCTAssertTrue(app.buttons["menu.newProject"].waitForExistence(timeout: 5))
        app.buttons["menu.newProject"].tap()
        let titleField = app.textFields["field.projectTitle"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(title)
        app.buttons["button.createProject"].tap()

        app.buttons["menu.add"].tap()
        XCTAssertTrue(app.buttons["menu.newPiece"].waitForExistence(timeout: 5))
        app.buttons["menu.newPiece"].tap()
        let pieceField = app.textFields["field.pieceName"]
        XCTAssertTrue(pieceField.waitForExistence(timeout: 5))
        pieceField.tap()
        pieceField.typeText(piece)
        if let repeatLength {
            let repeatField = app.textFields["field.pieceRepeat"]
            repeatField.tap()
            repeatField.typeText(repeatLength)
        }
        app.buttons["button.addPiece"].tap()
    }

    func testCreateCompleteUndoRelaunchRetainsCount() {
        createProject("UI Scarf", piece: "Front", repeatLength: "8")

        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        complete.tap()
        let completed = app.staticTexts["row.completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertTrue(completed.label.contains("2"), "two rows complete, got \(completed.label)")

        app.buttons["control.undo"].tap()
        XCTAssertTrue(completed.label.contains("1"), "undo returns to one row, got \(completed.label)")

        // Relaunch *without* the reset flag: the same durable store must
        // show the same count.
        app.launchArguments = []
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["row.completed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("1"),
                      "relaunched app must retain the committed count")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Issue #4 accessibility evidence: completed rows and the next repeat
    /// row are separate, explicitly-labelled elements — the exact strings a
    /// VoiceOver user hears (`label` is what assistive tech reads), never a
    /// merged container.
    func testCompletedAndNextRepeatRowsHaveSeparateAccessibilityLabels() {
        createProject("Label Scarf", piece: "Cuff", repeatLength: "8")

        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        complete.tap()

        let completed = app.staticTexts["row.completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertTrue(completed.label.contains("Completed rows 2"),
                      "completed readout must be its own labelled value, got \(completed.label)")

        let next = app.staticTexts["row.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(next.label.contains("Next repeat row 3"),
                      "next repeat row must be a distinct labelled value, got \(next.label)")
    }

    /// Issue #4 accessibility evidence recorded *in the simulator*:
    /// actionable controls are visible+hittable with 44pt-minimum frames,
    /// and the counter readouts expose their accessibility traits/labels
    /// (what VoiceOver would surface) rather than being decoration.
    func testControlsAreAccessibleHittableWith44PointFrames() {
        createProject("AX Scarf", piece: "Sleeve", repeatLength: "8")

        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        XCTAssertTrue(complete.isHittable, "Complete row must be hittable, not decoration")
        XCTAssertGreaterThanOrEqual(complete.frame.height, 44,
                                    "counter target must meet the 44pt floor, got \(complete.frame.height)")
        XCTAssertEqual(complete.label, "Complete row")

        let undo = app.buttons["control.undo"]
        XCTAssertTrue(undo.isHittable)
        XCTAssertGreaterThanOrEqual(undo.frame.height, 44)

        let completed = app.staticTexts["row.completed"]
        XCTAssertTrue(completed.exists)
        XCTAssertTrue(completed.label.hasPrefix("Completed rows"),
                      "VoiceOver label must identify completed rows, got \(completed.label)")
    }

    /// Issue #4: in the two-pane (regular-width) arrangement, reordering the
    /// panes and relaunching must preserve the committed count, and the
    /// reorder itself must never create a row event. The forced-two-pane
    /// launch argument renders the regular branch on the compact CI phone so
    /// this journey is actually executable on the pinned simulator.
    func testTwoPaneReorderPreservesStateAndEmitsNoRowEvent() {
        createProject("Pane Scarf", piece: "Back", repeatLength: "8")

        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()

        // Relaunch through the two-pane branch (no reset flag — the same
        // durable store must show the committed count).
        app.launchArguments = ["-rc-force-two-pane"]
        app.terminate()
        app.launch()
        let completed = app.staticTexts["row.completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 15))
        XCTAssertTrue(completed.label.contains("1"),
                      "durable count must survive branch switch, got \(completed.label)")

        app.buttons["control.paneOrder"].tap()
        XCTAssertTrue(completed.label.contains("1"),
                      "pane reorder is arrangement only — it must not change the count")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["row.completed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("1"),
                      "relaunch after reorder must show the same committed count")
    }
}
