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
}
