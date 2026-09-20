import Foundation

/// Errors surfaced by the pure row domain. Contains no UI or persistence types.
public enum RowDomainError: Error, Equatable, Sendable {
    case completedRowsOutOfRange
    case repeatLengthOutOfRange
    case pieceNotFound
    case projectNotFound
    case nothingToUndo
    case correctionRequiresConfirmation
    case correctionUnchanged
}

/// Pure repeat-aware row arithmetic from PLAN.md "Local data and row semantics".
///
/// - Completed counts are integers in `0...1_000_000`.
/// - Repeat length is either absent or in `1...10_000`.
/// - The *next repeat row* is the row the user works **next**: `(n mod L) + 1`,
///   never the last-completed row. With `L = 8`: `n = 0 => 1`, `n = 7 => 8`,
///   `n = 8 => 1` (with one full repeat complete).
public enum RowArithmetic {
    public static let maximumCompletedRows = 1_000_000
    public static let minimumRepeatLength = 1
    public static let maximumRepeatLength = 10_000

    public static func isValid(completedRows n: Int) -> Bool {
        n >= 0 && n <= maximumCompletedRows
    }

    public static func isValid(repeatLength l: Int?) -> Bool {
        guard let l else { return true }
        return l >= minimumRepeatLength && l <= maximumRepeatLength
    }

    /// Next row to work inside the current repeat, or `nil` when the piece has
    /// no repeat length or the inputs are out of bounds.
    public static func nextRepeatRow(completedRows n: Int, repeatLength l: Int?) -> Int? {
        guard isValid(completedRows: n), isValid(repeatLength: l), let l else { return nil }
        return (n % l) + 1
    }

    /// Whole repeats finished (`floor(n / L)`), or `nil` without a repeat length.
    public static func completedRepeats(completedRows n: Int, repeatLength l: Int?) -> Int? {
        guard isValid(completedRows: n), isValid(repeatLength: l), let l else { return nil }
        return n / l
    }
}

/// Canonical display copy. Completed rows and the next repeat row are always
/// presented as two separate, explicitly labelled values so a total count can
/// never be mistaken for the position inside a motif repeat.
public enum RowLabels {
    public static func completedRows(_ n: Int) -> String { "Completed rows \(n)" }
    public static func nextRepeatRow(_ n: Int) -> String { "Next repeat row \(n)" }
    public static func completedRepeats(_ count: Int) -> String { "Repeats complete \(count)" }
}
