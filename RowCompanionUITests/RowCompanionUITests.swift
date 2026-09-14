import XCTest

final class RowCompanionUITests: XCTestCase {
    @MainActor
    func testLaunchShowsHonestWorkspacePlaceholder() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["workspace.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["workspace.status"].exists)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
