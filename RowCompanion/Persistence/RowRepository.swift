import Foundation
import SwiftData

/// Repository-level failures. `saveFailed` means the durable commit was
/// rejected: the caller must treat the action as *not applied* (no apparent
/// success, no divergent in-memory count).
public enum RowRepositoryError: Error, Equatable {
    case projectNotFound(UUID)
    case pieceNotFound(UUID)
    case saveFailed(underlying: String)
    case unsupportedSchemaVersion(found: Int)
    case storeUnavailable(underlying: String)
}

/// Local-first, transactional row repository.
///
/// Atomicity contract (PLAN.md): every accepted action writes the piece count
/// update **and** its history event in one context save. If the save fails,
/// the in-memory changes are rolled back so a relaunch and the visible UI can
/// never diverge, and no error is swallowed into a fake success.
@MainActor
public final class RowRepository {
    public let container: ModelContainer
    private let context: ModelContext

    /// Fault-injection hook used by persistence tests: when set, the next
    /// durable commit throws instead of saving. Production never sets this.
    var testSaveFault: (() throws -> Void)?

    public init(storeURL: URL) throws {
        self.container = try RowStoreFactory.makeContainer(storeURL: storeURL)
        self.context = ModelContext(container)
    }

    /// Open a repository against an existing on-disk store (relaunch path).
    public static func open(storeURL: URL) throws -> RowRepository {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw RowRepositoryError.storeUnavailable(underlying: "missing store at \(storeURL.lastPathComponent)")
        }
        return try RowRepository(storeURL: storeURL)
    }

    // MARK: - Projects / pieces

    @discardableResult
    public func createProject(title: String) throws -> ProjectRecord {
        let now = Date()
        let stored = StoredProject(id: UUID(), title: title, createdAt: now, updatedAt: now)
        context.insert(stored)
        try commit()
        return stored.record
    }

    public func projects() throws -> [ProjectRecord] {
        let descriptor = FetchDescriptor<StoredProject>(sortBy: [SortDescriptor(\.createdAt)])
        return try context.fetch(descriptor).map(\.record)
    }

    @discardableResult
    public func addPiece(to projectID: UUID, name: String, repeatLength: Int? = nil, startingRows: Int = 0) throws -> PieceRecord {
        guard RowArithmetic.isValid(completedRows: startingRows) else {
            throw RowDomainError.completedRowsOutOfRange
        }
        guard RowArithmetic.isValid(repeatLength: repeatLength) else {
            throw RowDomainError.repeatLengthOutOfRange
        }
        guard try projectExists(projectID) else { throw RowRepositoryError.projectNotFound(projectID) }
        let stored = StoredPiece(id: UUID(), projectID: projectID, name: name, completedRows: startingRows, repeatLength: repeatLength, notes: "")
        context.insert(stored)
        try commit()
        return stored.record
    }

    public func pieces(in projectID: UUID) throws -> [PieceRecord] {
        let id = projectID
        let descriptor = FetchDescriptor<StoredPiece>(
            predicate: #Predicate { $0.projectID == id },
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map(\.record)
    }

    public func piece(_ pieceID: UUID) throws -> PieceRecord {
        guard let stored = try storedPiece(pieceID) else { throw RowRepositoryError.pieceNotFound(pieceID) }
        return stored.record
    }

    public func setNotes(_ notes: String, on pieceID: UUID) throws {
        guard let stored = try storedPiece(pieceID) else { throw RowRepositoryError.pieceNotFound(pieceID) }
        stored.notes = notes
        try commit()
    }

    // MARK: - Row actions (atomic event + count)

    /// Apply one row action atomically. On any failure (including an injected
    /// save fault) the context is reset, so neither the count nor the event
    /// becomes visible: no apparent success and no divergence on relaunch.
    /// Returns the recorded event, or `nil` for the no-op case where the
    /// repeat length is set to the value it already had.
    @discardableResult
    public func apply(_ action: RowAction, to pieceID: UUID) throws -> RowEvent? {
        guard let stored = try storedPiece(pieceID) else { throw RowRepositoryError.pieceNotFound(pieceID) }
        let piece = stored.record
        let history = try history(for: pieceID)
        let sequence = (history.map(\.sequence).max() ?? 0) + 1

        let transition: RowTransition
        do {
            transition = try RowReducer.reduce(piece: piece, history: history, action: action, at: Date(), nextSequence: sequence)
        } catch {
            // Pure validation failure: nothing was mutated; surface as-is.
            throw error
        }
        guard let event = transition.event else { return nil }

        do {
            stored.completedRows = transition.piece.completedRows
            context.insert(StoredRowEvent(
                id: event.id,
                pieceID: pieceID,
                sequence: event.sequence,
                kind: event.kind,
                before: event.before,
                after: event.after,
                createdAt: event.createdAt,
                undoneEventID: event.undoneEventID
            ))
            try commit()
            return event
        } catch {
            // `commit()` already rolled the context back on failure.
            throw error
        }
    }

    public func history(for pieceID: UUID) throws -> [RowEvent] {
        let id = pieceID
        let descriptor = FetchDescriptor<StoredRowEvent>(
            predicate: #Predicate { $0.pieceID == id },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return RowReducer.orderedHistory(try context.fetch(descriptor).map(\.record))
    }

    // MARK: - Internals

    private func storedPiece(_ pieceID: UUID) throws -> StoredPiece? {
        let id = pieceID
        let descriptor = FetchDescriptor<StoredPiece>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func projectExists(_ projectID: UUID) throws -> Bool {
        let id = projectID
        let descriptor = FetchDescriptor<StoredProject>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first != nil
    }

    private func latestEvent(for pieceID: UUID) throws -> RowEvent? {
        try history(for: pieceID).last
    }

    /// Durable commit point. `testSaveFault` runs *before* `save()` so tests
    /// can prove that a rejected write leaves no partial state visible. On
    /// any failure the context is rolled back so the in-memory view can never
    /// diverge from what actually reached disk.
    private func commit() throws {
        if let fault = testSaveFault {
            do {
                try fault()
            } catch {
                context.rollback()
                throw RowRepositoryError.saveFailed(underlying: String(describing: error))
            }
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw RowRepositoryError.saveFailed(underlying: String(describing: error))
        }
    }
}
