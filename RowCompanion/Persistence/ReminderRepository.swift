import Foundation
import SwiftData

// MARK: - Shaping reminders (issue #15)

/// Storage record for `ShapingReminderRecord`. Same flat foreign-key style
/// as the rest of the schema; `intervalRaw`/`endRow` optionality is kept as
/// true `Int?` columns so a nil repeat cadence never round-trips as a
/// fabricated interval of zero.
@Model
public final class StoredShapingReminder {
    @Attribute(.unique) public var id: UUID
    public var pieceID: UUID
    public var instruction: String
    public var intervalRaw: Int?
    public var startRow: Int
    public var endRow: Int?
    public var createdAt: Date

    public init(
        id: UUID,
        pieceID: UUID,
        instruction: String,
        intervalRaw: Int?,
        startRow: Int,
        endRow: Int?,
        createdAt: Date
    ) {
        self.id = id
        self.pieceID = pieceID
        self.instruction = instruction
        self.intervalRaw = intervalRaw
        self.startRow = startRow
        self.endRow = endRow
        self.createdAt = createdAt
    }

    var record: ShapingReminderRecord {
        ShapingReminderRecord(
            id: id,
            pieceID: pieceID,
            instruction: instruction,
            interval: intervalRaw,
            startRow: startRow,
            endRow: endRow
        )
    }
}

/// Repository surface for piece-scoped shaping reminders (issue #15).
///
/// Every mutation is one durable `commit()` — the same discipline as the
/// counter path, so a rejected save rolls back and the previous reminder set
/// stays exactly as it was on disk. Reads order reminders by creation time
/// then id so the workspace list is stable across relaunches.
@MainActor
extension RowRepository {
    /// All reminders for one piece in stable display order.
    public func reminders(for pieceID: UUID) throws -> [ShapingReminderRecord] {
        let id = pieceID
        let descriptor = FetchDescriptor<StoredShapingReminder>(
            predicate: #Predicate { $0.pieceID == id },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)]
        )
        return try context.fetch(descriptor).map(\.record)
    }

    /// Author a new reminder after pure validation; invalid reminders never
    /// reach disk (the caller surfaces `ReminderRules.validationProblems`).
    @discardableResult
    public func addReminder(
        to pieceID: UUID,
        instruction: String,
        interval: Int?,
        startRow: Int,
        endRow: Int? = nil
    ) throws -> ShapingReminderRecord {
        guard try storedPiece(pieceID) != nil else { throw RowRepositoryError.pieceNotFound(pieceID) }
        let candidate = ShapingReminderRecord(
            pieceID: pieceID,
            instruction: instruction,
            interval: interval,
            startRow: startRow,
            endRow: endRow
        )
        let problems = ReminderRules.validationProblems(for: candidate)
        guard problems.isEmpty else { throw RowRepositoryError.reminderInvalid(problems.joined(separator: " ")) }
        let stored = StoredShapingReminder(
            id: candidate.id,
            pieceID: pieceID,
            instruction: candidate.instruction,
            intervalRaw: candidate.interval,
            startRow: candidate.startRow,
            endRow: candidate.endRow,
            createdAt: Date()
        )
        context.insert(stored)
        try commit()
        return candidate
    }

    /// Remove one reminder durably. Missing ids are a no-op (the UI list can
    /// be momentarily stale while a delete confirm is open).
    public func removeReminder(id reminderID: UUID) throws {
        let id = reminderID
        let descriptor = FetchDescriptor<StoredShapingReminder>(predicate: #Predicate { $0.id == id })
        guard let stored = try context.fetch(descriptor).first else { return }
        context.delete(stored)
        try commit()
    }

    func storedReminders(pieceIDs: Set<UUID>) throws -> [StoredShapingReminder] {
        guard !pieceIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<StoredShapingReminder>(
            predicate: #Predicate { pieceIDs.contains($0.pieceID) }
        ))
    }
}
