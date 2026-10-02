import XCTest
@testable import RowCompanion

/// Pure rule coverage for piece-scoped shaping reminders (issue #15).
final class ReminderRulesTests: XCTestCase {
    private func once(_ start: Int, end: Int? = nil) -> ShapingReminderRecord {
        ShapingReminderRecord(pieceID: UUID(), instruction: "Begin shaping", interval: nil, startRow: start, endRow: end)
    }

    private func every(_ interval: Int, start: Int, end: Int? = nil) -> ShapingReminderRecord {
        ShapingReminderRecord(pieceID: UUID(), instruction: "Increase", interval: interval, startRow: start, endRow: end)
    }

    // MARK: - Due-next vs milestone separation

    func testOnceReminderIsDueExactlyAtItsRow() {
        let r = once(48)
        XCTAssertFalse(ReminderRules.isDueNext(reminder: r, completedRows: 46))
        XCTAssertTrue(ReminderRules.isDueNext(reminder: r, completedRows: 47)) // next row = 48
        XCTAssertFalse(ReminderRules.isDueNext(reminder: r, completedRows: 48))
        XCTAssertTrue(ReminderRules.milestoneReached(reminder: r, completedRows: 48))
        XCTAssertFalse(ReminderRules.milestoneReached(reminder: r, completedRows: 49))
    }

    func testRecurringReminderPhases() {
        let r = every(6, start: 4)
        XCTAssertTrue(ReminderRules.isDueNext(reminder: r, completedRows: 3))
        XCTAssertTrue(ReminderRules.isDueNext(reminder: r, completedRows: 9))
        XCTAssertFalse(ReminderRules.isDueNext(reminder: r, completedRows: 8))
        XCTAssertTrue(ReminderRules.milestoneReached(reminder: r, completedRows: 22))
        XCTAssertFalse(ReminderRules.milestoneReached(reminder: r, completedRows: 23))
    }

    func testEndRowBoundsBothPhases() {
        let r = every(6, start: 4, end: 16)
        XCTAssertTrue(ReminderRules.milestoneReached(reminder: r, completedRows: 16))
        XCTAssertFalse(ReminderRules.milestoneReached(reminder: r, completedRows: 22))
        XCTAssertFalse(ReminderRules.isDueNext(reminder: r, completedRows: 16))
        XCTAssertTrue(ReminderRules.hasEnded(reminder: r, completedRows: 17))
        XCTAssertFalse(ReminderRules.hasEnded(reminder: r, completedRows: 16))
    }

    // MARK: - Crossing several milestones (corrections / big undo)

    func testCorrectionSpanningSeveralMilestonesListsEveryCrossing() {
        let r = every(6, start: 4)
        XCTAssertEqual(ReminderRules.crossedRows(reminder: r, from: 3, to: 19), [4, 10, 16])
        XCTAssertEqual(ReminderRules.crossedRows(reminder: r, from: 19, to: 3), [16, 10, 4]) // event order follows direction
        XCTAssertEqual(ReminderRules.crossedRows(reminder: r, from: 10, to: 10), [])
    }

    func testCrossingRespectsEndRowAndStartRow() {
        let bounded = every(6, start: 4, end: 16)
        XCTAssertEqual(ReminderRules.crossedRows(reminder: bounded, from: 3, to: 100), [4, 10, 16])
        let early = every(6, start: 40)
        XCTAssertEqual(ReminderRules.crossedRows(reminder: early, from: 0, to: 2), [])
    }

    func testCrossingScalesToMillionRowSpansWithoutStalling() {
        let r = every(6, start: 4)
        let crossed = ReminderRules.crossedRows(reminder: r, from: 0, to: 999_999)
        XCTAssertEqual(crossed.first, 4)
        XCTAssertEqual(crossed.count, 166_666) // 4, 10, ..., 999_994
    }

    func testCrossingEquivalenceAgainstBruteForceScan() {
        for start in [1, 2, 17, 50] {
            for interval in [1, 3, 7, 100] {
                for previous in stride(from: 0, through: 400, by: 29) {
                    let r = every(interval, start: start)
                    let expected = (previous + 1...400).filter {
                        ReminderRules.milestoneReached(reminder: r, completedRows: $0)
                    }
                    XCTAssertEqual(ReminderRules.crossedRows(reminder: r, from: previous, to: 400), expected, "start \(start) interval \(interval) from \(previous)")
                }
            }
        }
    }

    // MARK: - Crossing notice: cap + direction, never silent loss

    func testCrossingNoticeCapsAndAnnouncesHiddenMilestones() {
        let r = every(1, start: 1)
        let notice = ReminderCrossingNotice(reminders: [r], previousCompletedRows: 0, newCompletedRows: 9)
        XCTAssertFalse(notice.isEmpty)
        XCTAssertTrue(notice.movedForward)
        XCTAssertEqual(notice.entries.count, ReminderCrossingNotice.displayCap)
        XCTAssertEqual(notice.hiddenCount, 9 - ReminderCrossingNotice.displayCap)
        XCTAssertTrue(notice.summaryText.contains("Count moved past 9 reminder milestones"), notice.summaryText)
        XCTAssertTrue(notice.summaryText.contains("+4 more in the reminder list"), notice.summaryText)
    }

    func testCrossingNoticeDirectionText() {
        let r = every(1, start: 1)
        let back = ReminderCrossingNotice(reminders: [r], previousCompletedRows: 9, newCompletedRows: 4)
        XCTAssertFalse(back.movedForward)
        XCTAssertTrue(back.summaryText.contains("Count moved back over"))
        XCTAssertEqual(back.entries.map(\.row), [9, 8, 7, 6, 5]) // event order: undo hits 9 first
        let empty = ReminderCrossingNotice(reminders: [r], previousCompletedRows: 5, newCompletedRows: 5)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Repeat edits / relaunch stability: rules are pure functions

    func testDueStateIsPureOverDurableCount() {
        // The same (reminder, count) pair always yields the same phase, so a
        // relaunch, repeat-length edit, or piece switch recomputes identical
        // due state — nothing is cached that could drift.
        let r = every(6, start: 4)
        for _ in 0..<3 {
            XCTAssertTrue(ReminderRules.isDueNext(reminder: r, completedRows: 33))
            XCTAssertTrue(ReminderRules.milestoneReached(reminder: r, completedRows: 34))
        }
    }

    // MARK: - Validation

    func testValidationRejectsBadAuthors() {
        XCTAssertEqual(ReminderRules.validationProblems(for: once(0)), ["Starting row must be 1 to 1000000."])
        XCTAssertFalse(ReminderRules.validationProblems(for: ShapingReminderRecord(pieceID: UUID(), instruction: "  ", interval: nil, startRow: 5)).isEmpty)
        XCTAssertEqual(ReminderRules.validationProblems(for: every(0, start: 5)), ["Interval must be 1 to 10000."])
        XCTAssertEqual(ReminderRules.validationProblems(for: every(6, start: 10, end: 5)), ["End row cannot be before the starting row."])
        XCTAssertTrue(ReminderRules.validationProblems(for: every(6, start: 1, end: 1_000_000)).isEmpty)
    }

    // MARK: - Tampered-store guards: non-positive intervals stay inert

    func testNonPositiveIntervalRemindersAreInert() {
        // A non-positive interval can only exist in a tampered store
        // (validation rejects it at authoring time). Every rule surface
        // must treat such a reminder as inert instead of trapping on
        // division/modulo by zero or a negative divisor.
        for tamperedInterval in [0, -6] {
            var r = every(6, start: 4)
            r.interval = tamperedInterval
            XCTAssertFalse(ReminderRules.isDueNext(reminder: r, completedRows: 3))
            XCTAssertFalse(ReminderRules.milestoneReached(reminder: r, completedRows: 4))
            XCTAssertFalse(ReminderRules.milestoneReached(reminder: r, completedRows: 10))
            XCTAssertEqual(ReminderRules.crossedRows(reminder: r, from: 0, to: 100), [])
            XCTAssertEqual(ReminderRules.crossedRows(reminder: r, from: 100, to: 0), [])
            let notice = ReminderCrossingNotice(reminders: [r], previousCompletedRows: 0, newCompletedRows: 50)
            XCTAssertTrue(notice.isEmpty)
        }
    }
}
