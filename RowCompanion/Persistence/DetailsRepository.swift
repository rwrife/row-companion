import Foundation
import SwiftData

/// Additive v9 entity (issue #20). One row per owner: either a project
/// (defaults) or a piece (overrides). `ownerID` is a UUID so a project and a
/// piece can never collide. Empty details are never stored.
@Model
public final class StoredProjectDetails {
    @Attribute(.unique) public var ownerID: UUID
    public var isPieceOverride: Bool
    public var material: String
    public var colorway: String
    public var selectedSize: String
    public var toolSizeMM: Double?
    public var gaugeStitchesPer10CM: Double?
    public var gaugeRowsPer10CM: Double?
    public var measurementMM: Double?

    public init(ownerID: UUID, isPieceOverride: Bool, details: ProjectDetails) {
        self.ownerID = ownerID
        self.isPieceOverride = isPieceOverride
        material = details.material; colorway = details.colorway; selectedSize = details.selectedSize
        toolSizeMM = details.toolSizeMM; gaugeStitchesPer10CM = details.gaugeStitchesPer10CM
        gaugeRowsPer10CM = details.gaugeRowsPer10CM; measurementMM = details.measurementMM
    }

    func apply(_ details: ProjectDetails) {
        material = details.material; colorway = details.colorway; selectedSize = details.selectedSize
        toolSizeMM = details.toolSizeMM; gaugeStitchesPer10CM = details.gaugeStitchesPer10CM
        gaugeRowsPer10CM = details.gaugeRowsPer10CM; measurementMM = details.measurementMM
    }

    var record: ProjectDetails {
        ProjectDetails(material: material, colorway: colorway, selectedSize: selectedSize,
                       toolSizeMM: toolSizeMM, gaugeStitchesPer10CM: gaugeStitchesPer10CM,
                       gaugeRowsPer10CM: gaugeRowsPer10CM, measurementMM: measurementMM)
    }
}

@MainActor
extension RowRepository {
    func storedDetails(_ ownerID: UUID) throws -> StoredProjectDetails? {
        let id = ownerID
        return try context.fetch(FetchDescriptor<StoredProjectDetails>(predicate: #Predicate { $0.ownerID == id })).first
    }

    /// Project-level defaults; empty when never set (legacy projects).
    public func details(forProject projectID: UUID) throws -> ProjectDetails {
        try storedDetails(projectID)?.record ?? ProjectDetails()
    }

    /// Raw piece overrides only (unset fields are empty/nil).
    public func details(forPiece pieceID: UUID) throws -> ProjectDetails {
        try storedDetails(pieceID)?.record ?? ProjectDetails()
    }

    /// Project defaults with piece overrides applied.
    public func effectiveDetails(forPiece pieceID: UUID) throws -> ProjectDetails {
        guard let piece = try storedPiece(pieceID) else { throw RowRepositoryError.pieceNotFound(pieceID) }
        return try details(forPiece: pieceID).overriding(details(forProject: piece.projectID))
    }

    public func setDetails(_ details: ProjectDetails, forProject projectID: UUID) throws {
        guard try storedProject(projectID) != nil else { throw RowRepositoryError.projectNotFound(projectID) }
        try store(details, ownerID: projectID, isPieceOverride: false)
    }

    public func setDetails(_ details: ProjectDetails, forPiece pieceID: UUID) throws {
        guard try storedPiece(pieceID) != nil else { throw RowRepositoryError.pieceNotFound(pieceID) }
        try store(details, ownerID: pieceID, isPieceOverride: true)
    }

    private func store(_ details: ProjectDetails, ownerID: UUID, isPieceOverride: Bool) throws {
        guard details.isValid else { throw RowRepositoryError.saveFailed(underlying: "Project details are out of range.") }
        let existing = try storedDetails(ownerID)
        switch (existing, details.isEmpty) {
        case (let object?, true): context.delete(object)
        case (let object?, false): object.apply(details)
        case (nil, true): return
        case (nil, false): context.insert(StoredProjectDetails(ownerID: ownerID, isPieceOverride: isPieceOverride, details: details))
        }
        try commit()
    }

    /// Details rows belonging to a set of owners (backup, deletion).
    func storedDetails(ownerIDs: Set<UUID>) throws -> [StoredProjectDetails] {
        guard !ownerIDs.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<StoredProjectDetails>(predicate: #Predicate { ownerIDs.contains($0.ownerID) }))
    }
}
