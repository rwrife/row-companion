import Foundation

/// Extra per-piece count. The existing completed-row counter remains independent.
public struct NamedCounter: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pieceID: UUID
    public var name: String
    public var unit: String
    public var startingValue: Int
    public var value: Int
    public var repeatLength: Int?
    public var advancesWithRows: Bool

    public var nextRepeat: Int? {
        RowArithmetic.nextRepeatRow(completedRows: value, repeatLength: repeatLength)
    }
}

public enum CounterEventKind: String, Codable, Sendable {
    case advance, correction, reset, undo
}

public struct CounterEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let counterID: UUID
    public let sequence: Int
    public let kind: CounterEventKind
    public let before: Int
    public let after: Int
    public let rowEventID: UUID?
    public let undoneEventID: UUID?
    public let createdAt: Date
}

public enum CounterRules {
    public static func valid(name: String, unit: String, startingValue: Int, repeatLength: Int?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80 && unit.count <= 32
            && RowArithmetic.isValid(completedRows: startingValue)
            && RowArithmetic.isValid(repeatLength: repeatLength)
    }

    public static func next(_ current: Int) throws -> Int {
        guard RowArithmetic.isValid(completedRows: current), current < RowArithmetic.maximumCompletedRows else {
            throw RowDomainError.completedRowsOutOfRange
        }
        return current + 1
    }
}
