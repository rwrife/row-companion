import XCTest
@testable import RowCompanion

final class RowArithmeticTests: XCTestCase {
    /// PLAN.md boundary table: with L=8, n=0 => next 1 / repeats 0;
    /// n=7 => next 8 / repeats 0; n=8 => next 1 / repeats 1.
    /// The value is the *next-to-work* row, never the last completed one.
    func testRepeatBoundariesForLengthEight() {
        XCTAssertEqual(RowArithmetic.nextRepeatRow(completedRows: 0, repeatLength: 8), 1)
        XCTAssertEqual(RowArithmetic.nextRepeatRow(completedRows: 7, repeatLength: 8), 8)
        XCTAssertEqual(RowArithmetic.nextRepeatRow(completedRows: 8, repeatLength: 8), 1)
        XCTAssertEqual(RowArithmetic.completedRepeats(completedRows: 0, repeatLength: 8), 0)
        XCTAssertEqual(RowArithmetic.completedRepeats(completedRows: 7, repeatLength: 8), 0)
        XCTAssertEqual(RowArithmetic.completedRepeats(completedRows: 8, repeatLength: 8), 1)
    }

    func testDisplayLabelsDistinguishCompletedFromNextToWork() {
        XCTAssertEqual(RowLabels.completedRows(8), "Completed rows 8")
        XCTAssertEqual(RowLabels.nextRepeatRow(1), "Next repeat row 1")
        XCTAssertNotEqual(RowLabels.completedRows(8), RowLabels.nextRepeatRow(1))
    }

    func testNoRepeatLengthMeansNoDerivedLabels() {
        XCTAssertNil(RowArithmetic.nextRepeatRow(completedRows: 5, repeatLength: nil))
        XCTAssertNil(RowArithmetic.completedRepeats(completedRows: 5, repeatLength: nil))
    }

    func testCountBounds() {
        XCTAssertTrue(RowArithmetic.isValid(completedRows: 0))
        XCTAssertTrue(RowArithmetic.isValid(completedRows: 1_000_000))
        XCTAssertFalse(RowArithmetic.isValid(completedRows: -1))
        XCTAssertFalse(RowArithmetic.isValid(completedRows: 1_000_001))
    }

    func testRepeatLengthBounds() {
        XCTAssertTrue(RowArithmetic.isValid(repeatLength: nil))
        XCTAssertTrue(RowArithmetic.isValid(repeatLength: 1))
        XCTAssertTrue(RowArithmetic.isValid(repeatLength: 10_000))
        XCTAssertFalse(RowArithmetic.isValid(repeatLength: 0))
        XCTAssertFalse(RowArithmetic.isValid(repeatLength: 10_001))
    }

    func testExtremesRemainInRange() {
        // Largest valid count with smallest and largest repeat lengths.
        XCTAssertEqual(RowArithmetic.nextRepeatRow(completedRows: 1_000_000, repeatLength: 1), 1)
        XCTAssertEqual(RowArithmetic.nextRepeatRow(completedRows: 1_000_000, repeatLength: 10_000), 1)
        XCTAssertEqual(RowArithmetic.completedRepeats(completedRows: 999_999, repeatLength: 10_000), 99)
    }
}
