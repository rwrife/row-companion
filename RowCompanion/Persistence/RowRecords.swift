import Foundation
import SwiftData

// SwiftData storage records for the local-first repository (PLAN.md data
// model). They intentionally mirror PLAN's flat foreign-key style
// (`projectID`, `pieceID` scalars) — no relationship graphs, which keeps the
// schema small and migration-friendly. CloudKit is never enabled (see
// `RowStoreFactory`), and these types never leave the Persistence layer:
// callers pass and receive the plain value records from `RowModels.swift`.

@Model
public final class StoredProject {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var record: ProjectRecord {
        ProjectRecord(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model
public final class StoredPiece {
    @Attribute(.unique) public var id: UUID
    public var projectID: UUID
    public var name: String
    public var completedRows: Int
    public var repeatLength: Int?
    public var notes: String

    public init(id: UUID, projectID: UUID, name: String, completedRows: Int, repeatLength: Int?, notes: String) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.completedRows = completedRows
        self.repeatLength = repeatLength
        self.notes = notes
    }

    var record: PieceRecord {
        PieceRecord(id: id, projectID: projectID, name: name, completedRows: completedRows, repeatLength: repeatLength, notes: notes)
    }
}

@Model
public final class StoredRowEvent {
    @Attribute(.unique) public var id: UUID
    public var pieceID: UUID
    public var sequence: Int
    /// `RowEventKind.rawValue`. Stored as a string so the on-disk shape stays
    /// readable and enum reordering can never silently corrupt history.
    public var kindRaw: String
    public var before: Int
    public var after: Int
    public var createdAt: Date
    public var undoneEventID: UUID?

    public init(id: UUID, pieceID: UUID, sequence: Int, kind: RowEventKind, before: Int, after: Int, createdAt: Date, undoneEventID: UUID?) {
        self.id = id
        self.pieceID = pieceID
        self.sequence = sequence
        self.kindRaw = kind.rawValue
        self.before = before
        self.after = after
        self.createdAt = createdAt
        self.undoneEventID = undoneEventID
    }

    var record: RowEvent {
        // An unrecognized on-disk kind can only come from a foreign/tampered
        // store. Map to the count-neutral, undo-ineligible configuration kind
        // rather than fabricating a count-changing kind.
        RowEvent(
            id: id,
            pieceID: pieceID,
            sequence: sequence,
            kind: RowEventKind(rawValue: kindRaw) ?? .repeatLengthChange,
            before: before,
            after: after,
            createdAt: createdAt,
            undoneEventID: undoneEventID
        )
    }
}
