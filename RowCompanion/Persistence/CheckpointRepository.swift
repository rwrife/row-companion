import Foundation
import SwiftData

/// Storage record for `ProgressCheckpointRecord` (issue #18).
/// Flat foreign-key style matching `StoredPiece` and `StoredShapingReminder`.
@Model
public final class StoredProgressCheckpoint {
    @Attribute(.unique) public var id: UUID
    public var pieceID: UUID
    public var name: String
    public var completedRows: Int
    public var repeatLength: Int?
    public var createdAt: Date

    public init(
        id: UUID,
        pieceID: UUID,
        name: String,
        completedRows: Int,
        repeatLength: Int?,
        createdAt: Date
    ) {
        self.id = id
        self.pieceID = pieceID
        self.name = name
        self.completedRows = completedRows
        self.repeatLength = repeatLength
        self.createdAt = createdAt
    }

    var record: ProgressCheckpointRecord {
        ProgressCheckpointRecord(
            id: id,
            pieceID: pieceID,
            name: name,
            completedRows: completedRows,
            repeatLength: repeatLength,
            createdAt: createdAt
        )
    }
}

/// Repository surface for piece-scoped progress checkpoints (issue #18).
@MainActor
extension RowRepository {
    /// Read all checkpoints for one piece, sorted chronologically.
    public func checkpoints(for pieceID: UUID) throws -> [ProgressCheckpointRecord] {
        let id = pieceID
        let descriptor = FetchDescriptor<StoredProgressCheckpoint>(
            predicate: #Predicate { $0.pieceID == id },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        return try context.fetch(descriptor).map(\.record)
    }

    /// Save a new progress checkpoint for a piece.
    @discardableResult
    public func addCheckpoint(
        to pieceID: UUID,
        name: String
    ) throws -> ProgressCheckpointRecord {
        guard let piece = try storedPiece(pieceID) else {
            throw RowRepositoryError.pieceNotFound(pieceID)
        }
        let existing = try checkpoints(for: pieceID).map(\.name)
        let problems = CheckpointRules.validationProblems(
            name: name,
            completedRows: piece.completedRows,
            existingNames: existing
        )
        guard problems.isEmpty else {
            throw RowRepositoryError.checkpointInvalid(problems.joined(separator: " "))
        }

        let record = ProgressCheckpointRecord(
            pieceID: pieceID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            completedRows: piece.completedRows,
            repeatLength: piece.repeatLength,
            createdAt: Date()
        )
        let stored = StoredProgressCheckpoint(
            id: record.id,
            pieceID: record.pieceID,
            name: record.name,
            completedRows: record.completedRows,
            repeatLength: record.repeatLength,
            createdAt: record.createdAt
        )
        context.insert(stored)
        try commit()
        return record
    }

    /// Restore to a checkpoint by applying a confirmed `.correction` action
    /// atomically. Does NOT delete past history or mutate checkpoints.
    @discardableResult
    public func restoreCheckpoint(
        _ checkpointID: UUID,
        confirmed: Bool
    ) throws -> RowEvent {
        guard confirmed else {
            throw RowDomainError.correctionRequiresConfirmation
        }
        let id = checkpointID
        let descriptor = FetchDescriptor<StoredProgressCheckpoint>(predicate: #Predicate { $0.id == id })
        guard let checkpoint = try context.fetch(descriptor).first else {
            throw RowRepositoryError.checkpointNotFound(checkpointID)
        }
        guard let event = try apply(.correction(to: checkpoint.completedRows, confirmed: true), to: checkpoint.pieceID) else {
            throw RowDomainError.correctionUnchanged
        }
        return event
    }

    /// Remove one checkpoint.
    public func removeCheckpoint(id checkpointID: UUID) throws {
        let id = checkpointID
        let descriptor = FetchDescriptor<StoredProgressCheckpoint>(predicate: #Predicate { $0.id == id })
        guard let stored = try context.fetch(descriptor).first else { return }
        context.delete(stored)
        try commit()
    }

    func storedCheckpoints(pieceIDs: Set<UUID>) throws -> [StoredProgressCheckpoint] {
        guard !pieceIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<StoredProgressCheckpoint>(
            predicate: #Predicate { pieceIDs.contains($0.pieceID) }
        ))
    }
}
