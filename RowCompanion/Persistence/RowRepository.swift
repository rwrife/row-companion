import Foundation
import SwiftData

/// Repository-level failures. `saveFailed` means the durable commit was
/// rejected: the caller must treat the action as *not applied* (no apparent
/// success, no divergent in-memory count).
public enum RowRepositoryError: Error, Equatable {
    case projectNotFound(UUID)
    case pieceNotFound(UUID)
    case documentNotFound(UUID)
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
        self.storeURL = storeURL
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

    /// First-launch or relaunch: create the store if absent, otherwise open
    /// the existing one. Used by the app process at startup only; tests keep
    /// using the explicit create/`open` pair to prove durability.
    public static func openOrCreate(storeURL: URL) throws -> RowRepository {
        let fm = FileManager.default
        try fm.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    // MARK: - Pattern documents (issue #3)

    /// The store file URL this repository was opened with; imported PDFs live
    /// in a sibling generated directory (`PDFImport.documentsDirectory`).
    public let storeURL: URL

    /// Import a user-picked PDF for `projectID` through the bounded importer.
    /// On success a `PatternDocument` record exists and the PDF bytes live at
    /// a generated app-owned path; on any `PDFImportError` nothing durable
    /// changed (no record, no file) because the record is only written after
    /// the importer reports success.
    @discardableResult
    public func importPatternDocument(from sourceURL: URL, for projectID: UUID) throws -> PatternDocumentRecord {
        guard try projectExists(projectID) else { throw RowRepositoryError.projectNotFound(projectID) }
        let accepted = try PDFImport.performImport(sourceURL: sourceURL, storeURL: storeURL)
        let stored = StoredPatternDocument(
            id: accepted.documentID,
            projectID: projectID,
            relativePath: "RowCompanionImported/\(accepted.storedFileName)",
            sha256: accepted.sha256,
            pageCount: accepted.pageCount
        )
        context.insert(stored)
        do {
            try commit()
        } catch {
            // The record was refused — remove the bytes the importer wrote so
            // no orphaned document survives without its metadata.
            let fileURL = PDFImport.documentsDirectory(storeURL: storeURL)
                .appendingPathComponent(accepted.storedFileName)
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        return stored.record
    }

    public func documents(in projectID: UUID) throws -> [PatternDocumentRecord] {
        let id = projectID
        let descriptor = FetchDescriptor<StoredPatternDocument>(
            predicate: #Predicate { $0.projectID == id },
            sortBy: [SortDescriptor(\.id)]
        )
        return try context.fetch(descriptor).map(\.record)
    }

    /// Absolute URL of a stored document's app-owned copy.
    public func documentFileURL(_ documentID: UUID) throws -> URL {
        guard let stored = try storedDocument(documentID) else {
            throw RowRepositoryError.documentNotFound(documentID)
        }
        return PDFImport.documentsDirectory(storeURL: storeURL)
            .appendingPathComponent(stored.relativePath.components(separatedBy: "/").last ?? stored.relativePath)
    }

    // MARK: - Reference state / viewport (issue #3)

    /// Read the piece's durable viewer state, clamped against the document's
    /// current page count. `nil` when the piece has never recorded any.
    public func referenceState(for pieceID: UUID) throws -> ReferenceState? {
        guard let stored = try storedReferenceState(pieceID) else { return nil }
        var state = stored.record
        if let documentID = state.documentID, let doc = try storedDocument(documentID) {
            state = ViewportClamp.clamp(state, pageCount: doc.pageCount)
        } else {
            // Document vanished (deleted/tampered): keep the page-agnostic
            // view state but stop pointing at a missing document.
            state.documentID = nil
            state = ViewportClamp.clamp(state, pageCount: 0)
        }
        return state
    }

    /// Persist the piece's viewer state. Everything is clamped through the
    /// pure rules before it reaches disk, so a hostile UI state cannot poison
    /// the store. Switching pieces/documents simply targets another pieceID —
    /// this API has no way to touch row counts.
    public func saveReferenceState(_ state: ReferenceState) throws {
        guard try storedPiece(state.pieceID) != nil else { throw RowRepositoryError.pieceNotFound(state.pieceID) }
        if let documentID = state.documentID, try storedDocument(documentID) == nil {
            throw RowRepositoryError.documentNotFound(documentID)
        }
        let clamped: ReferenceState
        if let documentID = state.documentID, let doc = try storedDocument(documentID) {
            clamped = ViewportClamp.clamp(state, pageCount: doc.pageCount)
        } else {
            clamped = ViewportClamp.clamp(state, pageCount: 0)
        }
        let stored: StoredReferenceState
        if let existing = try storedReferenceState(state.pieceID) {
            stored = existing
        } else {
            stored = StoredReferenceState(pieceID: clamped.pieceID, documentID: clamped.documentID, pageIndex: clamped.pageIndex, visibleRect: clamped.visibleRect, guideY: clamped.guideY)
            context.insert(stored)
        }
        stored.documentID = clamped.documentID
        stored.pageIndex = clamped.pageIndex
        stored.rectX = clamped.visibleRect.x
        stored.rectY = clamped.visibleRect.y
        stored.rectWidth = clamped.visibleRect.width
        stored.rectHeight = clamped.visibleRect.height
        stored.guideY = clamped.guideY
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

    private func storedDocument(_ documentID: UUID) throws -> StoredPatternDocument? {
        let id = documentID
        let descriptor = FetchDescriptor<StoredPatternDocument>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func storedReferenceState(_ pieceID: UUID) throws -> StoredReferenceState? {
        let id = pieceID
        let descriptor = FetchDescriptor<StoredReferenceState>(predicate: #Predicate { $0.pieceID == id })
        return try context.fetch(descriptor).first
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
