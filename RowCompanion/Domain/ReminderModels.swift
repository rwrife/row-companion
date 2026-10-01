import Foundation

/// A shaping instruction scoped to one piece (issue #15).
///
/// Two cadences exist and nothing more — no pattern-programming language:
/// - `.once(startRow:)` fires exactly at one row.
/// - `.every(interval:, startRow:)` fires when the *next row to work* is
///   `startRow`, `startRow + interval`, `startRow + 2*interval`, …
///
/// `endRow` (optional) stops a recurring reminder after that row has been
/// completed. Rows reuse the PLAN bounds: counts live in
/// `0...RowArithmetic.maximumCompletedRows`, and an `every` interval must be
/// a valid repeat-scale length (`1...RowArithmetic.maximumRepeatLength`).
public struct ShapingReminderRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let pieceID: UUID
    /// The maker's own instruction text, e.g. "Increase 1 st at each end".
    public var instruction: String
    /// `nil` means the reminder fires once at `startRow`; a value in
    /// `1...maximumRepeatLength` means it recurs every `interval` rows.
    public var interval: Int?
    /// First row (1-based *next row to work*) the instruction applies to.
    public var startRow: Int
    /// Optional last row after which a recurring reminder stops being due.
    public var endRow: Int?

    public init(
        id: UUID = UUID(),
        pieceID: UUID,
        instruction: String,
        interval: Int?,
        startRow: Int,
        endRow: Int? = nil
    ) {
        self.id = id
        self.pieceID = pieceID
        self.instruction = instruction
        self.interval = interval
        self.startRow = startRow
        self.endRow = endRow
    }

    public var isRecurring: Bool { interval != nil }
}

/// Pure due/reached/crossing rules. Everything here derives only from the
/// *durable* completed-row count, so a relaunch, an undo, a correction that
/// spans several milestones, or a repeat-length change can never desync what
/// the workspace shows — the same rules are re-run after every state change.
public enum ReminderRules {
    /// Validation problems with a reminder as authored. An empty array means
    /// the reminder is well-formed.
    public static func validationProblems(for reminder: ShapingReminderRecord) -> [String] {
        var problems: [String] = []
        if reminder.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Reminder needs instruction text.")
        }
        if reminder.startRow < 1 || reminder.startRow > RowArithmetic.maximumCompletedRows {
            problems.append("Starting row must be 1 to \(RowArithmetic.maximumCompletedRows).")
        }
        if let interval = reminder.interval, !RowArithmetic.isValid(repeatLength: interval) {
            problems.append("Interval must be 1 to \(RowArithmetic.maximumRepeatLength).")
        }
        if let endRow = reminder.endRow {
            if endRow < 1 || endRow > RowArithmetic.maximumCompletedRows {
                problems.append("End row must be 1 to \(RowArithmetic.maximumCompletedRows).")
            } else if endRow < reminder.startRow {
                problems.append("End row cannot be before the starting row.")
            }
        }
        return problems
    }

    /// True when the instruction applies to the *next row to work* given
    /// `completedRows` already done. This is the "instruction for the next
    /// row" surface — distinct from `milestoneReached`, which reports a row
    /// that was just *completed*.
    public static func isDueNext(reminder: ShapingReminderRecord, completedRows: Int) -> Bool {
        nextRow(completedRows: completedRows).flatMap { hits(reminder, atRow: $0) } ?? false
    }

    /// True when `completedRows` itself is a milestone row for this reminder
    /// (the "milestone reached after completing a row" surface).
    public static func milestoneReached(reminder: ShapingReminderRecord, completedRows: Int) -> Bool {
        guard completedRows >= reminder.startRow else { return false }
        guard withinEnd(reminder, atRow: completedRows) else { return false }
        guard let interval = reminder.interval else { return completedRows == reminder.startRow }
        return (completedRows - reminder.startRow) % interval == 0
    }

    /// True when a recurring reminder has run past its optional end row.
    public static func hasEnded(reminder: ShapingReminderRecord, completedRows: Int) -> Bool {
        guard let endRow = reminder.endRow else { return false }
        return completedRows > endRow
    }

    /// All milestone rows passed while the count moved from
    /// `previousCompletedRows` to `newCompletedRows`, in *event order* (the
    /// direction the count actually moved). A correction that jumps across
    /// several milestones lists every row it passed — instructions are never
    /// silently lost — while the caller caps how many are displayed at once
    /// so a huge correction cannot flood the screen.
    public static func crossedRows(
        reminder: ShapingReminderRecord,
        from previousCompletedRows: Int,
        to newCompletedRows: Int
    ) -> [Int] {
        guard previousCompletedRows != newCompletedRows else { return [] }
        let forward = newCompletedRows > previousCompletedRows
        let low = min(previousCompletedRows, newCompletedRows) + 1
        let high = max(previousCompletedRows, newCompletedRows)
        var hits: [Int] = []
        if let interval = reminder.interval {
            // Fast-forward to the first milestone ≥ low instead of scanning
            // up to a million rows one by one.
            var row = max(low, reminder.startRow)
            let offset = row - reminder.startRow
            if offset >= 0, let mod = positiveMod(offset, interval), mod != 0 {
                row += interval - mod
            }
            while row <= high, withinEnd(reminder, atRow: row) {
                hits.append(row)
                guard row + interval > row else { break } // overflow guard
                row += interval
            }
        } else if reminder.startRow >= low, reminder.startRow <= high,
                  withinEnd(reminder, atRow: reminder.startRow) {
            hits.append(reminder.startRow)
        }
        return forward ? hits : hits.reversed()
    }

    /// Short human-readable cadence copy for the reminder list row.
    public static func ruleDescription(for reminder: ShapingReminderRecord) -> String {
        let endSuffix = reminder.endRow.map { " until row \($0)" } ?? ""
        if let interval = reminder.interval {
            return "Every \(interval) rows from row \(reminder.startRow)\(endSuffix)"
        }
        return "Once at row \(reminder.startRow)"
    }

    /// The row the maker works next, or `nil` when the count is already at
    /// the domain maximum (nothing further to count).
    static func nextRow(completedRows: Int) -> Int? {
        guard completedRows < RowArithmetic.maximumCompletedRows else { return nil }
        return completedRows + 1
    }

    static func hits(_ reminder: ShapingReminderRecord, atRow row: Int) -> Bool {
        guard row >= reminder.startRow else { return false }
        guard withinEnd(reminder, atRow: row) else { return false }
        guard let interval = reminder.interval else { return row == reminder.startRow }
        return (row - reminder.startRow) % interval == 0
    }

    static func withinEnd(_ reminder: ShapingReminderRecord, atRow row: Int) -> Bool {
        guard let endRow = reminder.endRow else { return true }
        return row <= endRow
    }

    /// `(value mod interval)` with a non-negative result even if `value` is
    /// negative (callers stay in range, but the rule is total anyway).
    static func positiveMod(_ value: Int, _ interval: Int) -> Int? {
        guard interval > 0 else { return nil }
        let mod = value % interval
        return mod >= 0 ? mod : mod + interval
    }
}

/// One-shot, direction-aware summary of the milestones a single row action
/// crossed (issue #15). A correction that jumps several milestones lists
/// every instruction it passed (never silently lost) but the list is capped
/// so a huge correction cannot flood the screen — the count of hidden ones
/// is stated explicitly.
public struct ReminderCrossingNotice: Equatable, Sendable {
    /// Cap on distinct milestone rows shown per notice.
    public static let displayCap = 5

    /// True when the count moved forward (completed rows increased).
    public let movedForward: Bool
    /// Crossing entries in event order (order the count actually moved).
    public let entries: [ReminderCrossingEntry]
    /// Milestone rows hidden beyond `displayCap`.
    public let hiddenCount: Int

    public init(reminders: [ShapingReminderRecord], previousCompletedRows: Int, newCompletedRows: Int) {
        self.movedForward = newCompletedRows > previousCompletedRows
        var collected: [(row: Int, reminder: ShapingReminderRecord)] = []
        for reminder in reminders {
            for row in ReminderRules.crossedRows(reminder: reminder, from: previousCompletedRows, to: newCompletedRows) {
                collected.append((row, reminder))
            }
        }
        // Event order = the order milestone rows were passed in the actual
        // direction of movement.
        collected.sort { movedForward ? $0.row < $1.row : $0.row > $1.row }
        self.entries = collected.prefix(Self.displayCap).map { ReminderCrossingEntry(row: $0.row, instruction: $0.reminder.instruction) }
        self.hiddenCount = collected.count - self.entries.count
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Stable human summary for the whole notice (VoiceOver text and UI-test
    /// assertions). Action-neutral: complete, undo and corrections all use
    /// the same "the count moved" phrasing.
    public var summaryText: String {
        let total = entries.count + hiddenCount
        let verb = movedForward ? "Count moved past" : "Count moved back over"
        var text = "\(verb) \(total) reminder milestone\(total == 1 ? "" : "s")"
        for entry in entries {
            text += " · row \(entry.row): \(entry.instruction)"
        }
        if hiddenCount > 0 {
            text += " · +\(hiddenCount) more in the reminder list"
        }
        return text
    }
}

public struct ReminderCrossingEntry: Equatable, Sendable {
    public let row: Int
    public let instruction: String
    public init(row: Int, instruction: String) {
        self.row = row
        self.instruction = instruction
    }
}
