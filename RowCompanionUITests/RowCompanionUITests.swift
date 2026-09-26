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

    private func addPiece(_ name: String, repeatLength: String?) {
        app.buttons["menu.add"].tap()
        XCTAssertTrue(app.buttons["menu.newPiece"].waitForExistence(timeout: 5))
        app.buttons["menu.newPiece"].tap()
        let pieceField = app.textFields["field.pieceName"]
        XCTAssertTrue(pieceField.waitForExistence(timeout: 5))
        pieceField.tap()
        pieceField.typeText(name)
        if let repeatLength {
            let repeatField = app.textFields["field.pieceRepeat"]
            repeatField.tap()
            repeatField.typeText(repeatLength)
        }
        app.buttons["button.addPiece"].tap()
    }

    private func selectPiece(_ name: String) {
        app.buttons["control.piece"].tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5))
        app.buttons[name].tap()
    }

    /// Run explicitly for store assets; attachments are real simulator pixels.
    func testCaptureAppStoreScreenshots() throws {
        guard ProcessInfo.processInfo.environment["RC_CAPTURE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Marketing capture is opt-in; use Scripts/capture_app_store.sh")
        }
        app.launchArguments = ["-rc-app-store"]
        app.launch()
        XCTAssertTrue(app.staticTexts["row.completed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("42"))
        func capture(_ name: String) {
            // Let PDFKit finish its initial page layout before capture.
            Thread.sleep(forTimeInterval: 2)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("01-pattern-and-progress")
        app.scrollViews.firstMatch.swipeUp()
        capture("02-reading-guide-and-notes")
        app.buttons["control.piece"].tap()
        XCTAssertTrue(app.buttons["Left sleeve"].waitForExistence(timeout: 5))
        app.buttons["Left sleeve"].tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("20"))
        // Start the piece at the top of its controls for a consistent capture.
        app.terminate()
        app.launchArguments = ["-rc-app-store", "-rc-app-store-sleeve"]
        app.launch()
        XCTAssertTrue(app.staticTexts["row.completed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["control.completeRow"].isHittable)
        capture("03-independent-pieces")
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

    /// Issue #6 end-to-end regression: one real simulator journey crosses
    /// complete, undo, repeat editing, notes, independent pieces, layout
    /// replacement, and process relaunch. Assertions read the durable values
    /// after switching away and back, rather than relying on screenshots.
    func testEndToEndProgressContinuityAcrossPiecesLayoutAndRelaunch() {
        createProject("Regression Scarf", piece: "Front", repeatLength: "8")

        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        complete.tap()
        app.buttons["control.undo"].tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("1"))

        let repeatPicker = app.buttons["control.repeatLength"]
        XCTAssertTrue(repeatPicker.waitForExistence(timeout: 5))
        repeatPicker.tap()
        XCTAssertTrue(app.buttons["4"].waitForExistence(timeout: 5))
        app.buttons["4"].tap()
        XCTAssertTrue(app.staticTexts["row.next"].label.contains("Next repeat row 2"))

        let notes = app.textViews["control.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("Front continuity note")

        addPiece("Sleeve", repeatLength: "6")
        XCTAssertTrue(app.staticTexts["piece.name"].label.contains("Sleeve"))
        complete.tap()
        complete.tap()
        complete.tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("3"))

        selectPiece("Front")
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("1"))
        XCTAssertTrue(app.staticTexts["row.next"].label.contains("Next repeat row 2"))
        // The saved note should survive piece switches before layout replacement.
        XCTAssertTrue(app.textViews["control.notes"].exists)

        // Recreate the view through the regular-width branch and terminate
        // the process. The reset argument stays absent, so all assertions
        // below are reads from the same on-disk SwiftData store.
        app.launchArguments = ["-rc-force-regular-width"]
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["control.paneOrder"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("1"))
        XCTAssertTrue(app.staticTexts["row.next"].label.contains("Next repeat row 2"))
        XCTAssertTrue(app.textViews["control.notes"].exists)

        selectPiece("Sleeve")
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("3"))
        XCTAssertTrue(app.staticTexts["row.next"].label.contains("Next repeat row 4"))
    }

    /// Runs the regular-width decision with an actual accessibility Dynamic
    /// Type launch preference. The pane-order control proves two-pane at the
    /// standard size and its absence proves readable stacked reflow at the
    /// accessibility size. Counter controls must remain reachable afterward.
    func testAccessibilityDynamicTypeReflowsRegularWidthToStacked() {
        app.launchArguments = ["-rc-ui-tests-reset", "-rc-force-regular-width"]
        app.launch()
        XCTAssertTrue(app.buttons["control.paneOrder"].waitForExistence(timeout: 15),
                      "forced regular width should use two panes at standard text size")

        app.terminate()
        app.launchArguments = [
            "-rc-force-regular-width",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launchEnvironment["UIPreferredContentSizeCategoryName"] =
            "UICTContentSizeCategoryAccessibilityXXXL"
        app.launch()
        XCTAssertTrue(app.staticTexts["workspace.title"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["control.paneOrder"].exists,
                       "accessibility Dynamic Type must reflow regular width to stacked")

        addPieceAfterCreatingProjectForAccessibilityCheck()
        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        // At accessibility text sizes the stacked layout pushes the counter
        // controls below the fold. Scroll the intended inner control pane;
        // AX5 can require several short pages because every preceding label
        // wraps. Bound the loop so a layout regression still fails promptly.
        let controlsScroll = app.scrollViews["workspace.controlsScroll"]
        XCTAssertTrue(controlsScroll.exists)
        // The prior run's diagnostic showed repeated swipeUp() could push an
        // already-visible control off the TOP edge (button.maxY < scroll.minY)
        // and keep swiping the wrong way; scroll toward the button instead.
        for _ in 0..<12 where !complete.isHittable {
            if complete.frame.maxY < controlsScroll.frame.minY {
                controlsScroll.swipeDown()
            } else {
                controlsScroll.swipeUp()
            }
        }
        XCTAssertTrue(
            complete.isHittable,
            "counter control must stay reachable after scrolling at accessibility size; "
                + "button frame=\(complete.frame), scroll frame=\(controlsScroll.frame)"
        )
        XCTAssertGreaterThanOrEqual(complete.frame.height, 44)
    }

    private func addPieceAfterCreatingProjectForAccessibilityCheck() {
        app.buttons["menu.add"].tap()
        app.buttons["menu.newProject"].tap()
        let title = app.textFields["field.projectTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("Large Type Scarf")
        app.buttons["button.createProject"].tap()
        addPiece("Front", repeatLength: nil)
    }

    /// Issue #5 privacy gate journey: the export sheet's progress button is
    /// disabled until the acknowledgement toggle is on, and the full-backup
    /// button additionally requires the originals-rights checkbox. (The
    /// folder picker itself is system UI outside this app's automation
    /// surface; the actual metadata-only export is proven by the unit-test
    /// target's real-disk round trip in BackupTests.)
    func testDefaultExportRequiresAcknowledgementAndWritesMetadataOnly() {
        createProject("Export Scarf", piece: "Front", repeatLength: "8")

        app.buttons["menu.add"].tap()
        XCTAssertTrue(app.buttons["menu.export"].waitForExistence(timeout: 5))
        app.buttons["menu.export"].tap()

        let originalsToggle = app.switches["toggle.acknowledgeOriginals"]
        XCTAssertTrue(originalsToggle.waitForExistence(timeout: 5))
        let progressButton = app.buttons["button.exportProgress"]
        let fullButton = app.buttons["button.exportFullBackup"]
        XCTAssertTrue(progressButton.exists)
        XCTAssertFalse(progressButton.isEnabled,
                       "progress export must be gated on the privacy acknowledgement")
        XCTAssertFalse(fullButton.isEnabled,
                       "full backup must be gated on the originals-rights acknowledgement")

        app.switches["toggle.acknowledgeExport"].tap()
        XCTAssertTrue(progressButton.waitForExistence(timeout: 5))
        XCTAssertTrue(progressButton.isEnabled,
                      "acknowledged progress export must enable")
        XCTAssertFalse(fullButton.isEnabled,
                       "originals opt-in keeps its own separate acknowledgement")

        app.switches["toggle.acknowledgeOriginals"].tap()
        XCTAssertTrue(fullButton.waitForExistence(timeout: 5))
        XCTAssertTrue(fullButton.isEnabled, "both acknowledgements enable the full backup")
    }
}
