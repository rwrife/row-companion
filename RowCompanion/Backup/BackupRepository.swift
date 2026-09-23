import Foundation
import SwiftData

// MARK: - Backup / deletion surface on the repository (issue #5)
//
// `RowRepository` stays the single durable state owner: backup snapshots are
// taken *through* it (so they reflect one consistent committed state), and
// restore/deletion are repository operations so they share the same commit +
// rollback discipline as row actions. These methods live in an extension to
// keep the counter-critical core above untouched.

extension RowRepository {
    /// Errors specific to backup, restore, and deletion.
    public enum BackupRepositoryError: Error, Equatable {
        case exportFailed(String)
        /// Deletion was requested without the explicit confirmation the UI
        /// must obtain first; nothing was removed.
        case deletionRequiresConfirmation

        public var userMessage: String {
            switch self {
            case .exportFailed(let detail):
                return "The backup could not be produced (\(detail)). Nothing was exported."
            case .deletionRequiresConfirmation:
                return "Deletion was cancelled. Nothing was removed."
            }
        }
    }

    /// Build a *consistent* manifest of one project: counts, full event
    /// history, document metadata, and per-piece viewer state, all read from
    /// the same committed state on the main actor (no half-written store is
    /// ever copied — PLAN: "do not copy a live SQLite database file").
    @MainActor
    public func projectSnapshot(for projectID: UUID) throws -> BackupFormat.Manifest {
        let projects = try self.projects()
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw RowRepositoryError.projectNotFound(projectID)
        }
        let pieces = try self.pieces(in: projectID)
        var events: [BackupFormat.EventSnapshot] = []
        var references: [BackupFormat.ReferenceSnapshot] = []
        for piece in pieces {
            for event in try history(for: piece.id) {
                events.append(BackupFormat.EventSnapshot(
                    id: event.id,
                    pieceID: event.pieceID,
                    sequence: event.sequence,
                    kind: event.kind,
                    before: event.before,
                    after: event.after,
                    createdAt: event.createdAt,
                    undoneEventID: event.undoneEventID
                ))
            }
            if let state = try referenceState(for: piece.id) {
                references.append(BackupFormat.ReferenceSnapshot(
                    pieceID: state.pieceID,
                    documentID: state.documentID,
                    pageIndex: state.pageIndex,
                    visibleRect: state.visibleRect,
                    guideY: state.guideY
                ))
            }
        }
        let documents = try self.documents(in: projectID)
        let documentSnapshots: [BackupFormat.DocumentSnapshot] = documents.map { doc in
            // The recorded size is the size of the app-owned copy at export
            // time; a vanished file records 0 and therefore fails validation
            // on restore (fail closed) rather than exporting a phantom.
            let size = (try? documentFileURL(doc.id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return BackupFormat.DocumentSnapshot(
                id: doc.id,
                projectID: doc.projectID,
                relativePath: doc.relativePath,
                sha256: doc.sha256,
                pageCount: doc.pageCount,
                fileSize: size
            )
        }
        return BackupFormat.Manifest(
            createdAt: Date(),
            includesOriginals: false,
            project: BackupFormat.ProjectSnapshot(
                id: project.id, title: project.title,
                createdAt: project.createdAt, updatedAt: project.updatedAt
            ),
            pieces: pieces.map {
                BackupFormat.PieceSnapshot(
                    id: $0.id, projectID: $0.projectID, name: $0.name,
                    completedRows: $0.completedRows, repeatLength: $0.repeatLength, notes: $0.notes
                )
            },
            events: events,
            documents: documentSnapshots,
            references: references
        )
    }

    /// The raw bytes of a document's app-owned copy, for full backups that
    /// the user explicitly opted into. Throws when the file is unreadable —
    /// the caller must surface the failure rather than emit an incomplete
    /// backup with phantom entries.
    @MainActor
    public func documentFileBytes(_ documentID: UUID) throws -> Data {
        let url = try documentFileURL(documentID)
        guard let data = try? Data(contentsOf: url) else {
            throw BackupRepositoryError.exportFailed("stored pattern \(documentID.uuidString.prefix(8))… is unreadable")
        }
        return data
    }

    /// Insert a fully validated, ID-remapped snapshot as a brand-new project.
    /// Every record lands in one context save; on any failure (including an
    /// injected save fault) the context rolls back and *no* project exists —
    /// partial restores can never appear durable. Returns the new project ID.
    @discardableResult
    @MainActor
    public func insertRestoredProject(_ bundle: ProjectSnapshotBundle) throws -> UUID {
        let manifest = bundle.manifest
        let project = StoredProject(
            id: manifest.project.id, title: manifest.project.title,
            createdAt: manifest.project.createdAt, updatedAt: manifest.project.updatedAt
        )
        context.insert(project)
        for piece in manifest.pieces {
            context.insert(StoredPiece(
                id: piece.id, projectID: piece.projectID, name: piece.name,
                completedRows: piece.completedRows, repeatLength: piece.repeatLength, notes: piece.notes
            ))
        }
        for event in manifest.events {
            context.insert(StoredRowEvent(
                id: event.id, pieceID: event.pieceID, sequence: event.sequence,
                kind: event.kind, before: event.before, after: event.after,
                createdAt: event.createdAt, undoneEventID: event.undoneEventID
            ))
        }
        for document in manifest.documents {
            context.insert(StoredPatternDocument(
                id: document.id, projectID: document.projectID,
                relativePath: document.relativePath, sha256: document.sha256, pageCount: document.pageCount
            ))
        }
        for reference in manifest.references {
            context.insert(StoredReferenceState(
                pieceID: reference.pieceID, documentID: reference.documentID,
                pageIndex: reference.pageIndex, visibleRect: reference.visibleRect, guideY: reference.guideY
            ))
        }
        do {
            try commit()
        } catch {
            // Records rolled back inside commit(); the caller removes
            // any PDF bytes it wrote for this attempt.
            throw error
        }
        return project.id
    }

    /// Delete one project completely: its pieces, row events, documents
    /// (records + app-owned PDF copies), and reference states. Only files
    /// that live *inside* this store's generated document directory and are
    /// named by stored records are removed — user-exported files, OS
    /// backups, and anything outside the app-owned directory are untouched.
    /// The deletion is one durable save; if the save fails, nothing (records
    /// or files) is removed.
    @MainActor
    public func deleteProject(_ projectID: UUID, confirmed: Bool) throws {
        guard confirmed else {
            throw BackupRepositoryError.deletionRequiresConfirmation
        }
        guard let project = try storedProject(projectID) else {
            throw RowRepositoryError.projectNotFound(projectID)
        }
        let projectIDValue = projectID
        let pieceDescriptor = FetchDescriptor<StoredPiece>(predicate: #Predicate { $0.projectID == projectIDValue })
        let pieces = try context.fetch(pieceDescriptor)
        let pieceIDs = Set(pieces.map(\.id))

        let documentDescriptor = FetchDescriptor<StoredPatternDocument>(predicate: #Predicate { $0.projectID == projectIDValue })
        let documents = try context.fetch(documentDescriptor)

        let events = pieceIDs.isEmpty ? [] : try context.fetch(
            FetchDescriptor<StoredRowEvent>(predicate: #Predicate { pieceIDs.contains($0.pieceID) })
        )
        let references = pieceIDs.isEmpty ? [] : try context.fetch(
            FetchDescriptor<StoredReferenceState>(predicate: #Predicate { pieceIDs.contains($0.pieceID) })
        )

        // Only remove PDF bytes that verifiably live in the app-owned
        // directory (defense against tampered relativePaths).
        let documentsDir = PDFImport.documentsDirectory(storeURL: storeURL)
            .standardizedFileURL.path
        let ownedFileURLs: [URL] = documents.compactMap { doc in
            let fileName = doc.relativePath.components(separatedBy: "/").last ?? doc.relativePath
            guard !fileName.isEmpty, fileName != ".", fileName != ".." else { return nil }
            let url = URL(fileURLWithPath: documentsDir).appendingPathComponent(fileName).standardizedFileURL
            return url.path.hasPrefix(documentsDir + "/") ? url : nil
        }

        for object in events { context.delete(object) }
        for object in references { context.delete(object) }
        for object in documents { context.delete(object) }
        for object in pieces { context.delete(object) }
        context.delete(project)
        do {
            try commit()
        } catch {
            // Save failed and rolled back: the project and its files all
            // remain. Nothing was removed.
            throw error
        }
        // Records are durably gone; now remove their app-owned bytes. A
        // failure here leaves orphaned files but never orphaned records.
        for url in ownedFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
