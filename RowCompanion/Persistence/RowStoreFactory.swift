import Foundation
import SwiftData

/// Builds CloudKit-disabled local-only SwiftData containers (PLAN.md:
/// "SwiftData local persistence (CloudKit disabled)"). The store is always
/// created via `ModelConfiguration` without any cloud mirroring, so the
/// repository has no account, sync, or network surface.
@MainActor
public enum RowStoreFactory {
    /// App-private store location inside Application Support (file
    /// protection follows device lock policy; no CloudKit, see
    /// `configuration`).
    public static func defaultStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("RowCompanion", isDirectory: true)
            .appendingPathComponent("rowcompanion.sqlite")
    }

    /// Current on-disk schema version stamped into every fresh store.
    /// v2 adds `StoredPatternDocument` + `StoredReferenceState` (issue #3).
    public static let schemaVersion = 2

    public static var schema: Schema {
        Schema([StoredProject.self, StoredPiece.self, StoredRowEvent.self, StoredStoreInfo.self,
                StoredPatternDocument.self, StoredReferenceState.self])
    }

    /// Local, non-mirrored configuration for the given store URL.
    /// `cloudKitDatabase: .none` pins the CloudKit-disabled contract.
    public static func configuration(storeURL: URL) -> ModelConfiguration {
        ModelConfiguration(
            "RowCompanion",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
    }

    /// Container that refuses unknown future schema versions instead of
    /// reading data it does not understand.
    public static func makeContainer(storeURL: URL) throws -> ModelContainer {
        let config = configuration(storeURL: storeURL)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            throw RowRepositoryError.storeUnavailable(underlying: String(describing: error))
        }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<StoredStoreInfo>()
        let existing = try context.fetch(descriptor)
        if let info = existing.first {
            guard info.schemaVersion <= schemaVersion else {
                throw RowRepositoryError.unsupportedSchemaVersion(found: info.schemaVersion)
            }
        } else {
            context.insert(StoredStoreInfo(schemaVersion: schemaVersion, createdAt: Date()))
            try context.save()
        }
        return container
    }
}

/// Durable metadata record enabling versioned-store checks and migration
/// fixtures (an owned fixture can stamp a different version to prove the
/// reader fails closed).
@Model
public final class StoredStoreInfo {
    public var schemaVersion: Int
    public var createdAt: Date

    public init(schemaVersion: Int, createdAt: Date) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}
