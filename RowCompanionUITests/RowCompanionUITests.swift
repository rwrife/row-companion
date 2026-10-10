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

    /// Issue #18 journey: create checkpoint, complete more rows, verify
    /// chronological row history, return to checkpoint via confirmed
    /// correction event, survive relaunch.
    func testRowHistoryAndProgressCheckpointLifecycle() {
        createProject("Checkpoint Scarf", piece: "Body", repeatLength: "8")
        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        for _ in 0..<4 { complete.tap() }

        // Save a checkpoint at row 4. XCTest may auto-scroll this nested
        // ScrollView element on tap even if a window swipe misses that pane.
        let addCheckpoint = app.buttons["button.addCheckpoint"]
        XCTAssertTrue(addCheckpoint.waitForExistence(timeout: 5))
        addCheckpoint.tap()
        var scrollAttempts = 0
        let nameField = app.textFields["field.checkpoint.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Finished ribbing")
        app.buttons["button.checkpoint.save"].tap()

        // Advance to row 7
        for _ in 0..<3 { complete.tap() }
        let completed = app.staticTexts["row.completed"]
        XCTAssertTrue(completed.label.contains("7"))

        // Check history
        let showHistory = app.buttons["button.showHistory"]
        scrollAttempts = 0
        while !showHistory.isHittable && scrollAttempts < 8 {
            app.swipeUp()
            scrollAttempts += 1
        }
        showHistory.tap()
        XCTAssertTrue(app.staticTexts["history.timeline"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // Return to checkpoint (confirmed correction)
        let restoreButton = app.buttons["button.checkpoint.restore"]
        scrollAttempts = 0
        while !restoreButton.isHittable && scrollAttempts < 8 {
            app.swipeUp()
            scrollAttempts += 1
        }
        restoreButton.tap()
        let confirm = app.buttons["button.confirmRestoreCheckpoint"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertTrue(completed.label.contains("4"))

        // Relaunch
        app.launchArguments = []
        app.terminate()
        app.launch()
        XCTAssertTrue(completed.waitForExistence(timeout: 15))
        XCTAssertTrue(completed.label.contains("4"))
    }

    /// Issue #15 journey: author a durable shaping reminder, watch the
    /// next-row due banner appear while it is due, cross its milestone with a
    /// completing row (crossing notice), see due state recompute after undo,
    /// survive a correction and a relaunch — all with no notification
    /// permission (due state derives from the durable count, never timers).
    func testShapingReminderDueBannerCrossingAndRelaunch() {
        createProject("Reminder Scarf", piece: "Body", repeatLength: nil)

        // Author: default cadence is the most common case — one-shot at a
        // row. The reminder lives at the bottom of the control pane.
        let addReminder = app.buttons["button.addReminder"]
        var scrollAttempts = 0
        while !addReminder.isHittable && scrollAttempts < 8 {
            app.swipeUp()
            scrollAttempts += 1
        }
        XCTAssertTrue(addReminder.isHittable, "Add reminder control must be reachable by scrolling")
        addReminder.tap()

        let instructionField = app.textFields["field.reminder.instruction"]
        XCTAssertTrue(instructionField.waitForExistence(timeout: 5))
        instructionField.tap()
        instructionField.typeText("Begin shaping")
        let startField = app.textFields["field.reminder.startRow"]
        XCTAssertTrue(startField.waitForExistence(timeout: 5))
        startField.tap()
        clearNumberField(startField)
        startField.typeText("6")
        app.buttons["button.reminder.save"].tap()

        let reminderRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Begin shaping")).firstMatch
        XCTAssertTrue(reminderRow.waitForExistence(timeout: 5), "saved reminder must list in the pane")

        // n=5 => next row 6 => due.
        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        for _ in 0..<5 { complete.tap() }
        let dueBanner = app.staticTexts["reminder.dueBanner"]
        XCTAssertTrue(dueBanner.waitForExistence(timeout: 5), "reminder must show as due for the next row")
        XCTAssertTrue(dueBanner.label.contains("Begin shaping"), dueBanner.label)

        // Row 6 completes: milestone crossed, due banner retires, the
        // one-shot crossing notice names the milestone it passed.
        complete.tap()
        let notice = app.staticTexts["reminder.crossingNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("Count moved past 1 reminder milestone"), notice.label)
        XCTAssertTrue(notice.label.contains("row 6"), notice.label)
        // Root cause of the earlier CI miss: the reminder row previously
        // carried a container-level accessibilityIdentifier, which in the AX
        // tree overwrites every child identifier inside that row — so
        // `reminder.reached` never resolved. Children are identified
        // individually; keep it that way.
        let reached = app.staticTexts["reminder.reached"]
        XCTAssertTrue(reached.waitForExistence(timeout: 5), "milestone-reached state must persist in the list")

        // Undo recomputes everything from durable counts: row 6 is no longer
        // completed, so the reminder is due again and the notice flips to
        // the backward direction.
        app.buttons["control.undo"].tap()
        XCTAssertTrue(dueBanner.waitForExistence(timeout: 5), "undo must re-derive the due state")
        XCTAssertTrue(dueBanner.label.contains("Begin shaping"), dueBanner.label)
        XCTAssertTrue(notice.label.contains("Count moved back over"), notice.label)

        // A correction that jumps past the milestone crosses it too.
        // Cancel must leave the durable count untouched; reopening requires
        // a distinct destructive confirmation before any event is recorded.
        app.buttons["control.correct"].tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        let beforeCorrection = app.staticTexts["row.completed"]
        XCTAssertTrue(beforeCorrection.label.contains("5"), beforeCorrection.label)
        app.buttons["control.correct"].tap()
        let correctionField = app.alerts.textFields.firstMatch
        XCTAssertTrue(correctionField.waitForExistence(timeout: 5))
        correctionField.tap()
        clearNumberField(correctionField)
        correctionField.typeText("10")
        // Confirm through the explicit destructive alert action. On the
        // pinned iOS 26 simulator an embedded Toggle dismisses its alert
        // instead of retaining it; the action is the sole confirmation gate.
        let apply = app.buttons["control.applyCorrection"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()
        let corrected = app.staticTexts["row.completed"]
        XCTAssertTrue(corrected.waitForExistence(timeout: 5))
        XCTAssertTrue(corrected.label.contains("10"), corrected.label)
        XCTAssertTrue(notice.label.contains("Count moved past 1 reminder milestone"), notice.label)

        // Relaunch: reminders are durable; due/reached state re-derives from
        // the count (n=10, past the one-shot row 6 — not due, not reached).
        app.launchArguments = []
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["row.completed"].waitForExistence(timeout: 15))
        let survived = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Begin shaping")).firstMatch
        var rescroll = 0
        while !survived.isHittable && rescroll < 8 {
            app.swipeUp()
            rescroll += 1
        }
        XCTAssertTrue(survived.exists, "reminder must survive relaunch")
        XCTAssertFalse(app.staticTexts["reminder.dueBanner"].exists, "past its row, the one-shot reminder must not show due")
    }

    /// Clears a number-pad field whose text is pre-filled.
    private func clearNumberField(_ field: XCUIElement) {
        let length = (field.value as? String)?.count ?? 0
        for _ in 0..<length { field.typeText("\u{8}") }
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

extension RowCompanionUITests {
    func testLibraryDuplicateRenameArchiveSearchAndRelaunch() {
        createProject("Library Scarf", piece: "Body", repeatLength: "8")
        app.buttons["control.completeRow"].tap()
        app.buttons["menu.add"].tap()
        app.buttons["menu.library"].tap()
        XCTAssertTrue(app.buttons["library.open.Library Scarf"].waitForExistence(timeout: 5))
        app.buttons["library.sort"].tap()
        app.buttons["Title"].tap()
        app.buttons["library.actions.Library Scarf"].tap()
        app.buttons["Duplicate setup"].tap()
        XCTAssertTrue(app.switches["library.copyProgress"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["library.copyProgress"].value as? String, "0")
        app.buttons["library.save"].tap()
        XCTAssertTrue(app.buttons["library.open.Library Scarf Copy"].waitForExistence(timeout: 5))
        app.buttons["library.open.Library Scarf Copy"].tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("0"))
        app.buttons["menu.add"].tap()
        app.buttons["menu.library"].tap()
        app.buttons["library.actions.Library Scarf Copy"].tap()
        app.buttons["Rename"].tap()
        let field = app.textFields["library.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "Renamed Copy")
        app.buttons["library.save"].tap()
        app.buttons["library.actions.Renamed Copy"].tap()
        app.buttons["Mark Archived"].tap()
        XCTAssertFalse(app.buttons["library.open.Renamed Copy"].exists)
        app.buttons["library.status"].tap()
        app.buttons["Archived"].tap()
        XCTAssertTrue(app.buttons["library.open.Renamed Copy"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["menu.add"].tap()
        app.buttons["menu.library"].tap()
        app.buttons["library.status"].tap()
        app.buttons["Archived"].tap()
        XCTAssertTrue(app.buttons["library.open.Renamed Copy"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("No match")
        XCTAssertTrue(app.staticTexts["No matching projects."].waitForExistence(timeout: 5))
    }
}

extension RowCompanionUITests {
    /// Issue #19: focused counting shows the same selected piece, completes
    /// and undoes rows, and exiting returns the workspace with the count,
    /// piece selection, and notes surface exactly as they were. The two
    /// optional modes are explicit opt-ins whose switches are reachable.
    func testFocusedCountingKeepsProgressAndWorkspaceAcrossExit() {
        createProject("Focus Scarf", piece: "Front", repeatLength: "8")
        let complete = app.buttons["control.completeRow"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        let completed = app.staticTexts["row.completed"]
        XCTAssertTrue(completed.label.contains("1"))

        app.buttons["menu.add"].tap()
        app.buttons["focus.enter"].tap()
        let focusCompleted = app.staticTexts["focus.completed"]
        XCTAssertTrue(focusCompleted.waitForExistence(timeout: 5))
        XCTAssertTrue(focusCompleted.label.contains("Completed rows 1"))
        XCTAssertTrue(app.staticTexts["focus.piece"].label.contains("Front"))
        XCTAssertTrue(app.staticTexts["focus.next"].label.contains("Next repeat row 2"))

        app.buttons["focus.complete"].tap()
        XCTAssertTrue(focusCompleted.label.contains("Completed rows 2"))
        XCTAssertTrue(app.staticTexts["focus.next"].label.contains("Next repeat row 3"))
        app.buttons["focus.undo"].tap()
        XCTAssertTrue(focusCompleted.label.contains("Completed rows 1"))

        // Both optional modes are opt-in switches present in the mode.
        let haptics = app.switches["focus.haptics"]
        XCTAssertTrue(haptics.waitForExistence(timeout: 5))
        let keepAwake = app.switches["focus.keepAwake"]
        XCTAssertEqual(keepAwake.value as? String, "0", "keep-awake must default off")
        keepAwake.tap()
        let on = NSPredicate { _, _ in keepAwake.value as? String == "1" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: on, object: nil)], timeout: 5),
                       .completed, "keep-awake must flip on tap")
        keepAwake.tap()
        let off = NSPredicate { _, _ in keepAwake.value as? String == "0" }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: off, object: nil)], timeout: 5),
                       .completed, "keep-awake must flip back off")

        app.buttons["focus.exit"].tap()
        XCTAssertFalse(focusCompleted.exists, "focus cover must be dismissed")
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertTrue(completed.label.contains("Completed rows 1"),
                      "entering and exiting focus must not change the count")
        XCTAssertTrue(app.staticTexts["row.next"].label.contains("Next repeat row 2"))
        XCTAssertTrue(app.textViews["control.notes"].exists,
                      "the normal workspace (with its notes surface) resumes intact")
        XCTAssertTrue(app.buttons["control.piece"].label.contains("Front"),
                      "selected piece survives focus entry/exit")
    }
}

extension RowCompanionUITests {
    func testLibraryExplicitProgressCopyCompletionAndDeleteCancellation() {
        createProject("Progress Scarf", piece: "Body", repeatLength: "8")
        app.buttons["control.completeRow"].tap()
        app.buttons["control.completeRow"].tap()
        app.buttons["menu.add"].tap()
        app.buttons["menu.library"].tap()
        app.buttons["library.actions.Progress Scarf"].tap()
        app.buttons["Duplicate setup"].tap()
        XCTAssertTrue(app.switches["library.copyProgress"].waitForExistence(timeout: 5))
        let row = app.switches["library.copyProgress"]
        let nestedSwitch = row.switches.firstMatch
        let toggle = nestedSwitch.exists ? nestedSwitch : row
        toggle.tap()
        let enabled = NSPredicate { _, _ in toggle.value as? String == "1" }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Copy progress must be on before saving")
        guard result == .completed else { return }
        app.buttons["library.save"].tap()
        app.buttons["library.open.Progress Scarf Copy"].tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("2"))
        app.buttons["control.undo"].tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("1"))
        app.buttons["menu.add"].tap()
        app.buttons["menu.library"].tap()
        app.buttons["library.actions.Progress Scarf Copy"].tap()
        app.buttons["Mark Completed"].tap()
        app.buttons["library.status"].tap()
        app.buttons["Completed"].tap()
        app.buttons["library.actions.Progress Scarf Copy"].tap()
        app.buttons["Delete…"].tap()
        XCTAssertTrue(app.buttons["library.keepProject"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["library.keepProject"].firstMatch.tap()
        XCTAssertTrue(app.buttons["library.open.Progress Scarf Copy"].exists)
        app.buttons["library.actions.Progress Scarf Copy"].tap()
        app.buttons["Delete…"].tap()
        XCTAssertTrue(app.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.buttons["Delete Project"].tap()
        XCTAssertTrue(app.staticTexts["No completed projects."].waitForExistence(timeout: 5))
        app.buttons["library.status"].tap()
        app.buttons["Active"].tap()
        app.buttons["library.open.Progress Scarf"].tap()
        XCTAssertTrue(app.staticTexts["row.completed"].label.contains("2"))
    }
}
