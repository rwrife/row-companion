import XCTest
@testable import RowCompanion

final class CheckpointRulesTests: XCTestCase {
    func testNamesAndCountBounds() {
        XCTAssertFalse(CheckpointRules.validationProblems(name: " \n", completedRows: 0).isEmpty)
        XCTAssertFalse(CheckpointRules.validationProblems(name: "ribbing", completedRows: 0, existingNames: ["Ribbing"]).isEmpty)
        XCTAssertFalse(CheckpointRules.validationProblems(name: "End", completedRows: -1).isEmpty)
        XCTAssertFalse(CheckpointRules.validationProblems(name: "End", completedRows: 1_000_001).isEmpty)
        XCTAssertTrue(CheckpointRules.validationProblems(name: "End", completedRows: 1_000_000).isEmpty)
    }

    func testSummaryAndPhysicalWorkWarning() {
        let checkpoint = ProgressCheckpointRecord(pieceID: UUID(), name: "Ribbing", completedRows: 8, repeatLength: 8)
        XCTAssertEqual(CheckpointRules.summaryText(for: checkpoint), "Ribbing — row 8 (next repeat row 1)")
        XCTAssertTrue(CheckpointRules.restoreExplanation.contains("does not undo physical knitting"))
    }

    func testLargeHistoryKeepsEveryEventInSequenceOrder() {
        let pieceID = UUID()
        let events = (1...10_000).reversed().map {
            RowEvent(pieceID: pieceID, sequence: $0, kind: .completeRow, before: $0 - 1, after: $0, createdAt: Date())
        }
        XCTAssertEqual(RowReducer.orderedHistory(events).map(\.sequence), Array(1...10_000))
    }
}
