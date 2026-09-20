import Foundation

/// Plain value record for a knitting/crochet project (PLAN.md data model).
/// Deliberately free of SwiftData/SwiftUI so the domain stays testable
/// in isolation.
public struct ProjectRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Plain value record for a named piece with independent row progress.
public struct PieceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public var name: String
    /// Total completed rows, always in `0...RowArithmetic.maximumCompletedRows`.
    public var completedRows: Int
    /// Optional fixed repeat length in `1...10_000`, or `nil` when the piece
    /// has no repeat.
    public var repeatLength: Int?
    public var notes: String

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        completedRows: Int = 0,
        repeatLength: Int? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.completedRows = completedRows
        self.repeatLength = repeatLength
        self.notes = notes
    }

    /// The next row to work inside the current repeat, or `nil` without a
    /// repeat length.
    public var nextRepeatRow: Int? {
        RowArithmetic.nextRepeatRow(completedRows: completedRows, repeatLength: repeatLength)
    }

    /// Whole repeats finished, or `nil` without a repeat length.
    public var completedRepeats: Int? {
        RowArithmetic.completedRepeats(completedRows: completedRows, repeatLength: repeatLength)
    }
}

/// What a row event did. `undo` records the reversal of an eligible earlier
/// event; `repeatLengthChange` is a configuration change that preserves the
/// total count.
public enum RowEventKind: String, Codable, Equatable, Sendable {
    case completeRow
    case correction
    case undo
    case repeatLengthChange
}

/// One durable entry in a piece's reversible history. `sequence` is a dense
/// per-piece ordinal used for deterministic ordering (never relies on wall
/// clock ordering). `undoneEventID` is set only on `undo` events and names the
/// event whose effect it reverses, which makes double-undo detectable.
public struct RowEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pieceID: UUID
    public let sequence: Int
    public let kind: RowEventKind
    public let before: Int
    public let after: Int
    public let createdAt: Date
    public let undoneEventID: UUID?

    public init(
        id: UUID = UUID(),
        pieceID: UUID,
        sequence: Int,
        kind: RowEventKind,
        before: Int,
        after: Int,
        createdAt: Date,
        undoneEventID: UUID? = nil
    ) {
        self.id = id
        self.pieceID = pieceID
        self.sequence = sequence
        self.kind = kind
        self.before = before
        self.after = after
        self.createdAt = createdAt
        self.undoneEventID = undoneEventID
    }
}

/// Actions accepted by the pure row reducer.
public enum RowAction: Equatable, Sendable {
    case completeRow
    case undo
    /// A correction is only applied when `confirmed` is true (the user tapped
    /// an explicit confirm control). Unconfirmed corrections are rejected.
    case correction(to: Int, confirmed: Bool)
    /// Configuration change: sets the optional repeat length and preserves the
    /// total completed count.
    case setRepeatLength(Int?)
}
