import Foundation

/// Result of reducing one action: the updated piece plus exactly zero or one
/// new history entry. The persistence layer commits both atomically.
public struct RowTransition: Equatable, Sendable {
    public let piece: PieceRecord
    /// `nil` only for rejected no-op paths that still succeed (none today);
    /// every accepted action produces exactly one event.
    public let event: RowEvent?
}

/// Pure, deterministic row reducer. It never mutates external state, never
/// advances counts on piece/project switching or layout changes (switching is
/// not an action), and never wraps: every transition validates the resulting
/// count in `0...maximumCompletedRows`.
public enum RowReducer {
    /// Reduce one action against a piece and its history.
    ///
    /// - Parameters:
    ///   - piece: current piece state.
    ///   - history: all events for this piece, in any order (ordering is
    ///     re-derived from `sequence` deterministically).
    /// - Throws: `RowDomainError` for invalid input, nothing-to-undo,
    ///   unconfirmed or unchanged corrections.
    public static func reduce(
        piece: PieceRecord,
        history: [RowEvent],
        action: RowAction,
        at now: Date,
        nextSequence: Int
    ) throws -> RowTransition {
        guard RowArithmetic.isValid(completedRows: piece.completedRows),
              RowArithmetic.isValid(repeatLength: piece.repeatLength)
        else { throw RowDomainError.completedRowsOutOfRange }

        var updated = piece
        switch action {
        case .completeRow:
            let after = piece.completedRows + 1
            guard RowArithmetic.isValid(completedRows: after) else {
                throw RowDomainError.completedRowsOutOfRange
            }
            updated.completedRows = after

        case .undo:
            guard let target = undoTarget(in: history) else {
                throw RowDomainError.nothingToUndo
            }
            switch target.kind {
            case .completeRow, .correction:
                updated.completedRows = target.before
            case .undo:
                // Reversing an undo would re-apply an already reversed change.
                throw RowDomainError.nothingToUndo
            case .repeatLengthChange:
                // Configuration changes keep the same count; restoring one is a
                // no-op on the count and would not be an "eligible" event.
                throw RowDomainError.nothingToUndo
            }

        case .correction(let to, let confirmed):
            guard confirmed else { throw RowDomainError.correctionRequiresConfirmation }
            guard RowArithmetic.isValid(completedRows: to) else {
                throw RowDomainError.completedRowsOutOfRange
            }
            guard to != piece.completedRows else { throw RowDomainError.correctionUnchanged }
            updated.completedRows = to

        case .setRepeatLength(let length):
            guard RowArithmetic.isValid(repeatLength: length) else {
                throw RowDomainError.repeatLengthOutOfRange
            }
            guard length != piece.repeatLength else {
                // Same configuration: no event, no change.
                return RowTransition(piece: updated, event: nil)
            }
            // Total count is preserved by definition; only derived labels move.
            updated.repeatLength = length
        }

        let eventKind: RowEventKind
        let undoneEventID: UUID?
        switch action {
        case .completeRow:
            eventKind = .completeRow
            undoneEventID = nil
        case .undo:
            eventKind = .undo
            // undoTarget is guaranteed to exist here (threw otherwise).
            undoneEventID = undoTarget(in: history)?.id
        case .correction:
            eventKind = .correction
            undoneEventID = nil
        case .setRepeatLength:
            eventKind = .repeatLengthChange
            undoneEventID = nil
        }

        let event = RowEvent(
            pieceID: piece.id,
            sequence: nextSequence,
            kind: eventKind,
            before: piece.completedRows,
            after: updated.completedRows,
            createdAt: now,
            undoneEventID: undoneEventID
        )
        return RowTransition(piece: updated, event: event)
    }

    /// The most recent *eligible* event for a piece: the highest-sequence
    /// event that is not already reversed by a later `undo` and is not itself
    /// an `undo` or a configuration change. Repeated undos therefore walk
    /// backwards through history and can never reverse the same event twice.
    public static func undoTarget(in history: [RowEvent]) -> RowEvent? {
        let ordered = history.sorted { $0.sequence < $1.sequence }
        var reversed: Set<UUID> = []
        for event in ordered where event.kind == .undo {
            if let undone = event.undoneEventID {
                reversed.insert(undone)
            }
        }
        for event in ordered.reversed() {
            switch event.kind {
            case .completeRow, .correction:
                if !reversed.contains(event.id) { return event }
            case .undo, .repeatLengthChange:
                continue
            }
        }
        return nil
    }

    /// Deterministic history order for one piece.
    public static func orderedHistory(_ history: [RowEvent]) -> [RowEvent] {
        history.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.createdAt < $1.createdAt
        }
    }
}
