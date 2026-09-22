import Foundation
import Observation

/// Errors surfaced by the workspace layer to the UI.
public enum WorkspaceError: Error, Equatable {
    case noProjectSelected
    case noPieceSelected
    case importFailed(PDFImportError)
    case rowActionFailed(RowRepositoryError)
    case rowDomainFailed(RowDomainError)
    case other(String)

    public var userMessage: String {
        switch self {
        case .noProjectSelected: return "Create or select a project first."
        case .noPieceSelected: return "Add or select a piece first."
        case .importFailed(let error): return error.userMessage
        case .rowActionFailed: return "That change could not be saved. Nothing was counted."
        case .rowDomainFailed(let error):
            switch error {
            case .nothingToUndo: return "Nothing left to undo."
            case .correctionRequiresConfirmation: return "Corrections need confirmation."
            case .correctionUnchanged: return "That is already the current count."
            case .completedRowsOutOfRange: return "Row count is out of range."
            case .repeatLengthOutOfRange: return "Repeat length must be 1 to 10000."
            case .pieceNotFound, .projectNotFound: return "That item no longer exists."
            }
        case .other(let message): return message
        }
    }
}

/// The single durable state owner for the workspace (PLAN.md risk section:
/// "one durable state owner"). Everything visible is derived from repository
/// records keyed by stable piece/document IDs, so layout replacement (compact
/// ⇄ regular) can never lose or fork state, and nothing in this type has a
/// path from layout/view events to `RowAction` — switching pieces, switching
/// projects, rotating, or resizing can never advance a count.
@Observable
@MainActor
public final class WorkspaceModel {
    public let repository: RowRepository

    public private(set) var projects: [ProjectRecord] = []
    public private(set) var pieces: [PieceRecord] = []
    public private(set) var documents: [PatternDocumentRecord] = []
    public var selectedProjectID: UUID?
    public var selectedPieceID: UUID?
    /// Viewer state for the *currently selected* piece (loaded clamped).
    public private(set) var reference: ReferenceState?
    /// Transient error copy for an alert; the UI clears it after display.
    public var lastError: WorkspaceError?
    /// Last committed per-piece counts shown as a non-color status line.
    public var statusMessage = ""

    /// True while an import is running so controls can disable.
    public private(set) var isImporting = false

    public init(repository: RowRepository) {
        self.repository = repository
        reload()
        if let first = projects.first {
            select(project: first.id)
        } else {
            refreshStatus()
        }
    }

    // MARK: - Selection (never touches counts)

    public func select(project id: UUID?) {
        // Switching project: persist the outgoing piece's view state first.
        captureCurrentReference()
        selectedProjectID = id
        reload()
        selectPieceKeepState(pieces.first?.id)
    }

    public func select(piece id: UUID?) {
        if id == selectedPieceID { return }
        captureCurrentReference()
        selectPieceKeepState(id)
    }

    private func selectPieceKeepState(_ id: UUID?) {
        selectedPieceID = id
        loadReference()
        refreshStatus()
    }

    // MARK: - Mutation (each write goes through the durable repository)

    public func createProject(title: String) {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let project = try repository.createProject(title: title)
            select(project: project.id)
            statusMessage = "Project created."
        } catch {
            lastError = .rowActionFailed(error as? RowRepositoryError ?? .storeUnavailable(underlying: String(describing: error)))
        }
    }

    public func addPiece(name: String, repeatLength: Int?) {
        guard let projectID = selectedProjectID else {
            lastError = .noProjectSelected
            return
        }
        let cleanedName = name.trimmingCharacters(in: .whitespaces)
        guard !cleanedName.isEmpty else { return }
        do {
            let piece = try repository.addPiece(to: projectID, name: cleanedName, repeatLength: repeatLength)
            reload()
            selectPieceKeepState(piece.id)
        } catch {
            reportPersist(error)
        }
    }

    public func setNotes(_ notes: String) {
        guard let pieceID = selectedPieceID else { return }
        do {
            try repository.setNotes(notes, on: pieceID)
            reload()
        } catch {
            reportPersist(error)
        }
    }

    /// Row actions apply **only** from explicit user controls. On failure the
    /// repository has already rolled back, so we re-read the durable truth
    /// rather than optimistically updating a counter (PLAN: "a failed durable
    /// save must not display a committed counter update").
    public func completeRow() { rowAction(.completeRow) }
    public func undoRow() { rowAction(.undo) }
    public func correctCount(to value: Int, confirmed: Bool) { rowAction(.correction(to: value, confirmed: confirmed)) }
    public func setRepeatLength(_ length: Int?) { rowAction(.setRepeatLength(length)) }

    private func rowAction(_ action: RowAction) {
        guard let pieceID = selectedPieceID else {
            lastError = .noPieceSelected
            return
        }
        do {
            _ = try repository.apply(action, to: pieceID)
            reload(keepReference: true)
            refreshStatus()
        } catch let error as RowDomainError {
            lastError = .rowDomainFailed(error)
            reload(keepReference: true)
        } catch {
            lastError = .rowActionFailed(error as? RowRepositoryError ?? .storeUnavailable(underlying: String(describing: error)))
            reload(keepReference: true)
        }
    }

    // MARK: - PDF import

    public func importPDF(from url: URL) {
        guard let projectID = selectedProjectID else {
            lastError = .noProjectSelected
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let record = try repository.importPatternDocument(from: url, for: projectID)
            reload(keepReference: true)
            // Attach the new document to the selected piece's view state
            // without disturbing its stored page position beyond the clamp.
            if let pieceID = selectedPieceID {
                var state = reference ?? ReferenceState(pieceID: pieceID, documentID: record.id, pageIndex: 0, visibleRect: .full, guideY: nil)
                state.documentID = record.id
                state.pageIndex = 0
                state.visibleRect = .full
                try repository.saveReferenceState(state)
                loadReference()
            }
            statusMessage = "Pattern imported (\(record.pageCount) pages)."
        } catch let error as PDFImportError {
            lastError = .importFailed(error)
        } catch {
            reportPersist(error)
        }
    }

    // MARK: - Viewer state capture

    /// Called by the viewer when the user has moved/zoomed (page changed) —
    /// pure view state, never a row action.
    public func viewerMoved(pageIndex: Int, visibleRect: NormalizedRect) {
        guard let pieceID = selectedPieceID else { return }
        var state = reference ?? ReferenceState(pieceID: pieceID, documentID: documents.first?.id, pageIndex: pageIndex, visibleRect: visibleRect, guideY: nil)
        state.pageIndex = pageIndex
        state.visibleRect = visibleRect
        if state.documentID == nil { state.documentID = documents.first?.id }
        reference = ViewportClamp.clamp(state, pageCount: pageCountOf(state.documentID))
    }

    public func setGuide(y: Double?) {
        guard let pieceID = selectedPieceID else { return }
        var state = reference ?? ReferenceState(pieceID: pieceID, documentID: documents.first?.id, pageIndex: 0, visibleRect: .full, guideY: y)
        state.guideY = ViewportClamp.clamp(guideY: y)
        reference = ViewportClamp.clamp(state, pageCount: pageCountOf(state.documentID))
        persistReference(reference)
    }

    /// Persist the in-memory reference (called on piece/project switch and
    /// when the viewer pauses). Failures keep the *stored* value consistent
    /// because a failed commit rolls back inside the repository.
    public func captureCurrentReference() {
        persistReference(reference)
    }

    private func persistReference(_ state: ReferenceState?) {
        guard let state else { return }
        do {
            try repository.saveReferenceState(state)
        } catch {
            // View-state persistence is best-effort: a failure must never
            // fabricate success, but it also must not corrupt counts (they
            // are not involved). Surface it quietly on the status line.
            statusMessage = "View position could not be saved."
        }
    }

    // MARK: - Derived reads

    public var selectedPiece: PieceRecord? {
        pieces.first { $0.id == selectedPieceID }
    }

    public var referenceDocumentURL: URL? {
        guard let id = reference?.documentID else { return nil }
        return try? repository.documentFileURL(id)
    }

    public var referencePageCount: Int? {
        guard let id = reference?.documentID,
              let doc = documents.first(where: { $0.id == id }) else { return nil }
        return doc.pageCount
    }

    private func pageCountOf(_ documentID: UUID?) -> Int {
        guard let documentID, let doc = documents.first(where: { $0.id == documentID }) else { return 0 }
        return doc.pageCount
    }

    private func loadReference() {
        guard let pieceID = selectedPieceID else {
            reference = nil
            return
        }
        do {
            reference = try repository.referenceState(for: pieceID)
        } catch {
            reference = nil
        }
    }

    public func reload(keepReference: Bool = false) {
        let previousReference = reference
        do {
            projects = try repository.projects()
            if let projectID = selectedProjectID {
                documents = try repository.documents(in: projectID)
                pieces = try repository.pieces(in: projectID)
            } else {
                documents = []
                pieces = []
            }
        } catch {
            lastError = .rowActionFailed(error as? RowRepositoryError ?? .storeUnavailable(underlying: String(describing: error)))
        }
        if keepReference { reference = previousReference }
    }

    private func refreshStatus() {
        guard let piece = selectedPiece else {
            statusMessage = selectedProjectID == nil
                ? "Create a project to begin."
                : "Add a piece to begin counting."
            return
        }
        var message = RowLabels.completedRows(piece.completedRows)
        if let next = piece.nextRepeatRow, let repeats = piece.completedRepeats {
            message += " · \(RowLabels.nextRepeatRow(next)) · \(RowLabels.completedRepeats(repeats))"
        }
        statusMessage = message
    }

    private func reportPersist(_ error: Error) {
        if let repoError = error as? RowRepositoryError {
            lastError = .rowActionFailed(repoError)
        } else if let domainError = error as? RowDomainError {
            lastError = .rowDomainFailed(domainError)
        } else {
            lastError = .other(String(describing: error))
        }
    }
}
