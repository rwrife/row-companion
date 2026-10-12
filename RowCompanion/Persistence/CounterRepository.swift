import Foundation
import SwiftData

/// Additive entities: existing row history and piece records remain untouched.
@Model
public final class StoredNamedCounter {
    @Attribute(.unique) public var id: UUID
    public var pieceID: UUID
    public var name: String
    public var unit: String
    public var startingValue: Int
    public var value: Int
    public var repeatLength: Int?
    public var advancesWithRows: Bool

    public init(id: UUID, pieceID: UUID, name: String, unit: String, startingValue: Int,
                value: Int, repeatLength: Int?, advancesWithRows: Bool) {
        self.id = id; self.pieceID = pieceID; self.name = name; self.unit = unit
        self.startingValue = startingValue; self.value = value
        self.repeatLength = repeatLength; self.advancesWithRows = advancesWithRows
    }

    var record: NamedCounter {
        NamedCounter(id: id, pieceID: pieceID, name: name, unit: unit, startingValue: startingValue,
                     value: value, repeatLength: repeatLength, advancesWithRows: advancesWithRows)
    }
}

@Model
public final class StoredCounterEvent {
    @Attribute(.unique) public var id: UUID
    public var counterID: UUID
    public var sequence: Int
    public var kindRaw: String
    public var before: Int
    public var after: Int
    public var rowEventID: UUID?
    public var undoneEventID: UUID?
    public var createdAt: Date

    public init(_ event: CounterEvent) {
        id = event.id; counterID = event.counterID; sequence = event.sequence
        kindRaw = event.kind.rawValue; before = event.before; after = event.after
        rowEventID = event.rowEventID; undoneEventID = event.undoneEventID; createdAt = event.createdAt
    }

    var record: CounterEvent? {
        guard let kind = CounterEventKind(rawValue: kindRaw) else { return nil }
        return CounterEvent(id: id, counterID: counterID, sequence: sequence, kind: kind,
                            before: before, after: after, rowEventID: rowEventID,
                            undoneEventID: undoneEventID, createdAt: createdAt)
    }
}

@MainActor
extension RowRepository {
    public func counters(for pieceID: UUID) throws -> [NamedCounter] {
        let id = pieceID
        return try context.fetch(FetchDescriptor<StoredNamedCounter>(predicate: #Predicate { $0.pieceID == id },
            sortBy: [SortDescriptor(\.name)])).map(\.record)
    }

    public func counterHistory(for counterID: UUID) throws -> [CounterEvent] {
        let id = counterID
        return try context.fetch(FetchDescriptor<StoredCounterEvent>(predicate: #Predicate { $0.counterID == id },
            sortBy: [SortDescriptor(\.sequence)])).compactMap(\.record)
    }

    @discardableResult
    public func addCounter(to pieceID: UUID, name: String, unit: String, startingValue: Int = 0,
                           repeatLength: Int? = nil, advancesWithRows: Bool = false) throws -> NamedCounter {
        guard try storedPiece(pieceID) != nil else { throw RowRepositoryError.pieceNotFound(pieceID) }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CounterRules.valid(name: cleanName, unit: unit, startingValue: startingValue, repeatLength: repeatLength),
              try !counters(for: pieceID).contains(where: { $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame }) else {
            throw RowRepositoryError.counterInvalid
        }
        let object = StoredNamedCounter(id: UUID(), pieceID: pieceID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), startingValue: startingValue,
            value: startingValue, repeatLength: repeatLength, advancesWithRows: advancesWithRows)
        context.insert(object)
        try commit()
        return object.record
    }

    public func setCounterLink(_ counterID: UUID, advancesWithRows: Bool) throws {
        let counter = try requireCounter(counterID)
        counter.advancesWithRows = advancesWithRows
        try commit()
    }

    @discardableResult
    public func changeCounter(_ counterID: UUID, to value: Int, confirmed: Bool, reset: Bool = false) throws -> CounterEvent {
        guard confirmed, RowArithmetic.isValid(completedRows: value) else { throw RowRepositoryError.counterInvalid }
        let counter = try requireCounter(counterID)
        guard value != counter.value else { throw RowRepositoryError.counterInvalid }
        let history = try counterHistory(for: counterID)
        let event = CounterEvent(id: UUID(), counterID: counterID, sequence: history.count + 1,
            kind: reset ? .reset : .correction, before: counter.value, after: value,
            rowEventID: nil, undoneEventID: nil, createdAt: Date())
        counter.value = value
        context.insert(StoredCounterEvent(event))
        try commit()
        return event
    }

    @discardableResult
    public func undoCounter(_ counterID: UUID) throws -> CounterEvent {
        let counter = try requireCounter(counterID)
        let history = try counterHistory(for: counterID)
        let undone = Set(history.compactMap(\.undoneEventID))
        guard let target = history.reversed().first(where: { $0.kind != .undo && $0.rowEventID == nil && !undone.contains($0.id) }),
              counter.value == target.after else { throw RowRepositoryError.counterInvalid }
        let event = CounterEvent(id: UUID(), counterID: counterID, sequence: history.count + 1,
            kind: .undo, before: counter.value, after: target.before,
            rowEventID: nil, undoneEventID: target.id, createdAt: Date())
        counter.value = event.after
        context.insert(StoredCounterEvent(event))
        try commit()
        return event
    }

    @discardableResult
    public func advanceCounter(_ counterID: UUID) throws -> CounterEvent {
        let counter = try requireCounter(counterID)
        let value = try CounterRules.next(counter.value)
        let event = CounterEvent(id: UUID(), counterID: counterID,
            sequence: try counterHistory(for: counterID).count + 1,
            kind: .advance, before: counter.value, after: value,
            rowEventID: nil, undoneEventID: nil, createdAt: Date())
        counter.value = value
        context.insert(StoredCounterEvent(event))
        try commit()
        return event
    }

    func requireCounter(_ counterID: UUID) throws -> StoredNamedCounter {
        let id = counterID
        guard let counter = try context.fetch(FetchDescriptor<StoredNamedCounter>(predicate: #Predicate { $0.id == id })).first else {
            throw RowRepositoryError.counterNotFound(counterID)
        }
        return counter
    }

    /// Return linked counters to be displayed before any row action. No implicit linking.
    public func linkedCounters(for pieceID: UUID) throws -> [NamedCounter] {
        try counters(for: pieceID).filter(\.advancesWithRows)
    }

    /// Row-action hook. Linked counters are already validated by `apply`,
    /// which inserts their events in the same commit.
    func counterChanges(for pieceID: UUID, rowEvent: RowEvent, undo: Bool) throws -> [(StoredNamedCounter, CounterEvent)] {
        let candidates: [NamedCounter]
        if undo {
            candidates = try counters(for: pieceID).filter { counter in
                (try? counterHistory(for: counter.id).contains { $0.rowEventID == rowEvent.undoneEventID && $0.kind == .advance }) ?? false
            }
        } else {
            candidates = try counters(for: pieceID).filter(\.advancesWithRows)
        }
        var changes: [(StoredNamedCounter, CounterEvent)] = []
        for member in candidates {
            let stored = try requireCounter(member.id)
            let past = try counterHistory(for: member.id)
            let next: Int
            let undoneEventID: UUID?
            if undo {
                guard let target = past.first(where: { $0.rowEventID == rowEvent.undoneEventID && $0.kind == .advance }),
                      stored.value == target.after,
                      !past.contains(where: { $0.undoneEventID == target.id }) else {
                    throw RowRepositoryError.counterInvalid
                }
                next = target.before
                undoneEventID = target.id
            } else {
                next = try CounterRules.next(stored.value)
                undoneEventID = nil
            }
            changes.append((stored, CounterEvent(id: UUID(), counterID: member.id,
                sequence: past.count + 1, kind: undo ? .undo : .advance,
                before: stored.value, after: next, rowEventID: rowEvent.id,
                undoneEventID: undoneEventID, createdAt: rowEvent.createdAt)))
        }
        return changes
    }

    /// Delete a counter and its whole event history in one commit. Row
    /// history is untouched; past linked row events remain durable and their
    /// counter events simply disappear with the counter.
    public func removeCounter(id counterID: UUID) throws {
        let counter = try requireCounter(counterID)
        let events = try context.fetch(FetchDescriptor<StoredCounterEvent>(predicate: #Predicate { $0.counterID == counterID }))
        for event in events { context.delete(event) }
        context.delete(counter)
        try commit()
    }
}
