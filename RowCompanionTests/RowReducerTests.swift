import XCTest
@testable import RowCompanion

final class RowReducerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let pieceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func makePiece(rows: Int = 0, length: Int? = nil) -> PieceRecord {
        PieceRecord(id: pieceID, projectID: UUID(), name: "sleeve", completedRows: rows, repeatLength: length)
    }

    /// Drives a sequence of actions and returns the final piece + history.
    private func run(_ piece: PieceRecord, _ actions: [RowAction]) throws -> (PieceRecord, [RowEvent]) {
        var current = piece
        var history: [RowEvent] = []
        var sequence = 1
        for action in actions {
            let transition = try RowReducer.reduce(piece: current, history: history, action: action, at: t0, nextSequence: sequence)
            current = transition.piece
            if let event = transition.event {
                history.append(event)
                sequence += 1
            }
        }
        return (current, history)
    }

    func testCompleteProducesOneEventPerRow() throws {
        let (piece, history) = try run(makePiece(rows: 0, length: 8), [.completeRow, .completeRow, .completeRow])
        XCTAssertEqual(piece.completedRows, 3)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(history.map(\.kind), [.completeRow, .completeRow, .completeRow])
        XCTAssertEqual(history.map(\.after), [1, 2, 3])
        XCTAssertEqual(history.map(\.before), [0, 1, 2])
    }

    func testUndoRestoresLatestEligibleEvent() throws {
        let (piece, history) = try run(makePiece(rows: 0, length: 8), [.completeRow, .completeRow, .undo])
        XCTAssertEqual(piece.completedRows, 1)
        let undo = try XCTUnwrap(history.last)
        XCTAssertEqual(undo.kind, .undo)
        XCTAssertEqual(undo.before, 2)
        XCTAssertEqual(undo.after, 1)
        XCTAssertEqual(undo.undoneEventID, history.first { $0.kind == .completeRow && $0.after == 2 }?.id)
    }

    func testRepeatedUndoCannotReverseSameEventTwice() throws {
        // Complete twice, undo twice, then a third undo must find nothing.
        do {
            _ = try run(makePiece(rows: 0), [.completeRow, .completeRow, .undo, .undo, .undo])
            XCTFail("third undo should throw nothingToUndo")
        } catch let error as RowDomainError {
            XCTAssertEqual(error, .nothingToUndo)
        }
    }

    func testUndoOnFreshPieceThrows() {
        XCTAssertThrowsError(try RowReducer.reduce(piece: makePiece(rows: 0), history: [], action: .undo, at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .nothingToUndo)
        }
    }

    func testCorrectionRequiresConfirmation() {
        XCTAssertThrowsError(try RowReducer.reduce(piece: makePiece(rows: 3), history: [], action: .correction(to: 10, confirmed: false), at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .correctionRequiresConfirmation)
        }
    }

    func testConfirmedCorrectionRecordsEventAndValidatesRange() throws {
        let piece = makePiece(rows: 3, length: 8)
        let ok = try RowReducer.reduce(piece: piece, history: [], action: .correction(to: 10, confirmed: true), at: t0, nextSequence: 1)
        XCTAssertEqual(ok.piece.completedRows, 10)
        XCTAssertEqual(ok.event?.kind, .correction)
        XCTAssertEqual(ok.event?.before, 3)
        XCTAssertEqual(ok.event?.after, 10)

        XCTAssertThrowsError(try RowReducer.reduce(piece: piece, history: [], action: .correction(to: -1, confirmed: true), at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .completedRowsOutOfRange)
        }
        XCTAssertThrowsError(try RowReducer.reduce(piece: piece, history: [], action: .correction(to: 1_000_001, confirmed: true), at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .completedRowsOutOfRange)
        }
    }

    func testCorrectionUnchangedThrows() {
        XCTAssertThrowsError(try RowReducer.reduce(piece: makePiece(rows: 3), history: [], action: .correction(to: 3, confirmed: true), at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .correctionUnchanged)
        }
    }

    func testRepeatLengthChangePreservesCountAndRecordsConfiguration() throws {
        let piece = makePiece(rows: 9, length: 8)
        let transition = try RowReducer.reduce(piece: piece, history: [], action: .setRepeatLength(4), at: t0, nextSequence: 1)
        XCTAssertEqual(transition.piece.completedRows, 9, "total count preserved")
        XCTAssertEqual(transition.piece.repeatLength, 4)
        XCTAssertEqual(transition.piece.nextRepeatRow, 2, "derived labels recompute")
        XCTAssertEqual(transition.piece.completedRepeats, 2)
        XCTAssertEqual(transition.event?.kind, .repeatLengthChange)
        XCTAssertEqual(transition.event?.before, 9)
        XCTAssertEqual(transition.event?.after, 9)
    }

    func testRepeatLengthBoundsEnforced() {
        let piece = makePiece(rows: 1)
        XCTAssertThrowsError(try RowReducer.reduce(piece: piece, history: [], action: .setRepeatLength(0), at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .repeatLengthOutOfRange)
        }
        XCTAssertThrowsError(try RowReducer.reduce(piece: piece, history: [], action: .setRepeatLength(10_001), at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .repeatLengthOutOfRange)
        }
    }

    func testCompleteAtMaximumDoesNotWrap() {
        let piece = makePiece(rows: 1_000_000)
        XCTAssertThrowsError(try RowReducer.reduce(piece: piece, history: [], action: .completeRow, at: t0, nextSequence: 1)) { error in
            XCTAssertEqual(error as? RowDomainError, .completedRowsOutOfRange)
        }
    }

    func testUndoSkipsNonEligibleConfigurationEvents() throws {
        // The newest event is a configuration change; undo must walk back to
        // the latest count-changing event and leave the repeat length alone.
        let (piece, _) = try run(makePiece(rows: 0, length: 8), [.completeRow, .completeRow, .setRepeatLength(4), .undo])
        XCTAssertEqual(piece.completedRows, 1)
        XCTAssertEqual(piece.repeatLength, 4, "configuration untouched by undo of an earlier event")
    }

    func testPieceHistoriesAreIndependent() throws {
        let a = makePiece(rows: 0)
        let b = PieceRecord(id: UUID(), projectID: a.projectID, name: "back", completedRows: 7)
        let historyA = [
            RowEvent(pieceID: a.id, sequence: 1, kind: .completeRow, before: 0, after: 1, createdAt: t0),
            RowEvent(pieceID: a.id, sequence: 2, kind: .completeRow, before: 1, after: 2, createdAt: t0),
        ]
        let historyB = [RowEvent(pieceID: b.id, sequence: 1, kind: .completeRow, before: 6, after: 7, createdAt: t0)]

        let ta = try RowReducer.reduce(piece: a, history: historyA, action: .undo, at: t0, nextSequence: 3)
        let tb = try RowReducer.reduce(piece: b, history: historyB, action: .undo, at: t0, nextSequence: 2)
        XCTAssertEqual(ta.piece.completedRows, 1)
        XCTAssertEqual(tb.piece.completedRows, 6)
    }

    func testOrderingIsDeterministicFromSequenceNotClock() {
        // Events constructed out of chronological order still order by sequence.
        let early = RowEvent(id: UUID(), pieceID: pieceID, sequence: 1, kind: .completeRow, before: 0, after: 1, createdAt: Date(timeIntervalSince1970: 500))
        let late = RowEvent(id: UUID(), pieceID: pieceID, sequence: 2, kind: .completeRow, before: 1, after: 2, createdAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(RowReducer.orderedHistory([late, early]).map(\.sequence), [1, 2])
    }

    /// Property-style loop: any mix of valid actions never produces a count
    /// outside bounds, and next-repeat-row always stays within 1...L.
    func testInvariantSweepOverActionSequences() throws {
        for seed: UInt64 in 0..<200 {
            var rng = SeededGenerator(seed: seed)
            var piece = makePiece(rows: Int.random(in: 0..<50, using: &rng), length: Bool.random(using: &rng) ? Int.random(in: 1...8, using: &rng) : nil)
            var history: [RowEvent] = []
            var sequence = 1
            for _ in 0..<25 {
                let action: RowAction
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: action = .completeRow
                case 1: action = .undo
                case 2: action = .correction(to: Int.random(in: 0...1_000_000, using: &rng), confirmed: true)
                default: action = .setRepeatLength(Bool.random(using: &rng) ? Int.random(in: 1...10_000, using: &rng) : nil)
                }
                if let transition = try? RowReducer.reduce(piece: piece, history: history, action: action, at: t0, nextSequence: sequence) {
                    piece = transition.piece
                    if let event = transition.event { history.append(event); sequence += 1 }
                }
                // Invariants after every step (accepted or rejected).
                XCTAssertTrue(RowArithmetic.isValid(completedRows: piece.completedRows), "seed \(seed): count bounds")
                XCTAssertTrue(RowArithmetic.isValid(repeatLength: piece.repeatLength), "seed \(seed): length bounds")
                if let next = piece.nextRepeatRow, let length = piece.repeatLength {
                    XCTAssertTrue((1...length).contains(next), "seed \(seed): next in 1...L")
                }
            }
        }
    }
}

/// Deterministic RNG so sweep failures reproduce exactly.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        return x
    }
}
