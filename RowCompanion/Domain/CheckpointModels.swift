import Foundation

/// A named progress checkpoint scoped to one piece (issue #18).
///
/// Acceptance criteria:
/// - Scoped to each piece with an explicit, non-empty name (e.g. "Finished ribbing").
/// - Preserves the piece's completed row count and repeat configuration at the
///   time of checkpoint creation.
/// - Returning to a checkpoint requires explicit confirmation and records a new
///   `.correction` event (never silently deletes past history).
/// - Changing recorded progress does NOT undo physical knitting or crochet.
public struct ProgressCheckpointRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pieceID: UUID
    public var name: String
    /// The piece's completed-row count when this checkpoint was saved.
    public var completedRows: Int
    /// Optional repeat length captured at checkpoint creation.
    public var repeatLength: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        pieceID: UUID,
        name: String,
        completedRows: Int,
        repeatLength: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.pieceID = pieceID
        self.name = name
        self.completedRows = completedRows
        self.repeatLength = repeatLength
        self.createdAt = createdAt
    }
}

/// Pure validation and presentation rules for progress checkpoints.
public enum CheckpointRules {
    /// Validation problems for a candidate checkpoint. Empty array means valid.
    public static func validationProblems(
        name: String,
        completedRows: Int,
        existingNames: [String] = []
    ) -> [String] {
        var problems: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            problems.append("Checkpoint name cannot be empty.")
        }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            problems.append("A checkpoint with that name already exists for this piece.")
        }
        if !RowArithmetic.isValid(completedRows: completedRows) {
            problems.append("Row count is out of range.")
        }
        return problems
    }

    /// Descriptive summary of a checkpoint for lists and confirmation sheets.
    public static func summaryText(for checkpoint: ProgressCheckpointRecord) -> String {
        var text = "\(checkpoint.name) — row \(checkpoint.completedRows)"
        if let length = checkpoint.repeatLength,
           let next = RowArithmetic.nextRepeatRow(completedRows: checkpoint.completedRows, repeatLength: length) {
            text += " (next repeat row \(next))"
        }
        return text
    }

    /// Explanation shown before confirming a return to a checkpoint.
    public static let restoreExplanation = "Returning to this checkpoint records a new correction in your history so your record stays intact. Changing recorded progress does not undo physical knitting or crochet."
}
