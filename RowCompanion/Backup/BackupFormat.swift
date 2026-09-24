import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Versioned backup format (issue #5)
//
// Two artifact kinds share one manifest schema:
//
// * **Progress export** (default): `manifest.json` only. It never contains
//   PDF bytes, the user's original filenames, or raw source paths — only
//   generated app-owned relative paths recorded at import time.
// * **Full folder backup** (explicit opt-in): `manifest.json` plus an
//   `originals/` directory of app-owned PDF copies. Because the copies may
//   contain licensed/private material, presenting this option requires a
//   copyright/privacy warning (see `BackupService.warnings`).
//
// The manifest is a versioned snapshot of the *consistent* repository state
// (counts + full event history + per-piece viewport). Restoring always
// creates a **new project with remapped IDs** after the staged copy passes
// every hostile-archive check below — there is no overwrite and no merge.

/// Every way a progress export or full backup can be refused, with copy
/// suitable for an alert. Every rejection happens while the snapshot is
/// still staged, so a refused restore never mutates existing projects.
public enum BackupError: Error, Equatable, Sendable {
    case schemaTooNew(version: Int)
    case malformedManifest
    case traversalPath(entry: String)
    case absolutePath(entry: String)
    case symlink(entry: String)
    case notRegularFile(entry: String)
    case duplicatePath(entry: String)
    case duplicateID(kind: String, id: String)
    case danglingReference(kind: String, id: String)
    case invalidCountOrHistory(detail: String)
    case hashMismatch(entry: String)
    case sizeMismatch(entry: String)
    case missingFile(entry: String)
    case oversizedTotal(byteCount: Int)
    case exportFailed(underlying: String)

    public var userMessage: String {
        switch self {
        case .schemaTooNew(let v):
            return "This backup was made by a newer version of Row Companion (schema \(v)). Update the app before restoring it."
        case .malformedManifest:
            return "The backup's manifest could not be read. Nothing was restored."
        case .traversalPath(let e):
            return "The backup contains an invalid file reference (“\(e)”). Nothing was restored."
        case .absolutePath(let e):
            return "The backup contains an invalid file reference (“\(e)”). Nothing was restored."
        case .symlink(let e):
            return "The backup contains a link instead of a file (“\(e)”). Links are never restored. Nothing was restored."
        case .notRegularFile(let e):
            return "The backup contains an unexpected item (“\(e)”). Nothing was restored."
        case .duplicatePath(let e):
            return "The backup lists the same file twice (“\(e)”). Nothing was restored."
        case .duplicateID(let kind, let id):
            return "The backup lists the same \(kind) twice (ID \(id.prefix(8))…). Nothing was restored."
        case .danglingReference(let kind, let id):
            return "The backup refers to a \(kind) it does not contain (ID \(id.prefix(8))…). Nothing was restored."
        case .invalidCountOrHistory(let detail):
            return "The backup's row counts or history are inconsistent (\(detail)). Nothing was restored."
        case .hashMismatch(let e):
            return "A backup file did not match its recorded checksum (“\(e)”). Nothing was restored."
        case .sizeMismatch(let e):
            return "A backup file did not match its recorded size (“\(e)”). Nothing was restored."
        case .missingFile(let e):
            return "A file listed in the backup is missing (“\(e)”). Nothing was restored."
        case .oversizedTotal(let bytes):
            return "This backup is too large (\(ByteCount.Format.mebibytes(bytes))). The limit is \(ByteCount.Format.mebibytes(BackupFormat.maximumTotalBytes))."
        case .exportFailed:
            return "The backup could not be written. Check available storage and try again."
        }
    }
}

/// Pure backup-format logic: constants, hostile-archive validation, and the
/// ID-remapping snapshot transform. No FileManager, no SwiftData, no
/// SwiftUI — the whole hostile-input surface is testable off-device.
public enum BackupFormat {
    /// Manifest schema version written into every snapshot.
    public static let schemaVersion = 1
    /// Restores refuse manifests stamped by a future schema (fail closed).
    public static let minimumSupportedVersion = 1
    /// Combined file-size cap for a staged restore (PLAN.md: 200 MiB).
    public static let maximumTotalBytes = 200 * 1024 * 1024
    /// Hard bound on manifest size, enforced before JSON parsing so a
    /// hostile multi-gigabyte manifest never reaches the decoder.
    public static let maximumManifestBytes = 16 * 1024 * 1024
    /// Directory inside a full backup folder that holds PDF copies.
    public static let originalsDirectoryName = "originals"
    public static let manifestFileName = "manifest.json"

    // MARK: - Snapshot value types

    public struct ProjectSnapshot: Codable, Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct PieceSnapshot: Codable, Equatable, Sendable {
        public var id: UUID
        public var projectID: UUID
        public var name: String
        public var completedRows: Int
        public var repeatLength: Int?
        public var notes: String
    }

    public struct EventSnapshot: Codable, Equatable, Sendable {
        public var id: UUID
        public var pieceID: UUID
        public var sequence: Int
        public var kind: RowEventKind
        public var before: Int
        public var after: Int
        public var createdAt: Date
        public var undoneEventID: UUID?
    }

    public struct DocumentSnapshot: Codable, Equatable, Sendable {
        public var id: UUID
        public var projectID: UUID
        /// App-owned relative path, e.g. `RowCompanionImported/<uuid>.pdf`.
        /// Never a user-picked filename.
        public var relativePath: String
        public var sha256: String
        public var pageCount: Int
        /// Byte size of the app-owned copy, recorded so a staged restore can
        /// verify the size before hashing.
        public var fileSize: Int
    }

    public struct ReferenceSnapshot: Codable, Equatable, Sendable {
        public var pieceID: UUID
        public var documentID: UUID?
        public var pageIndex: Int
        public var visibleRect: NormalizedRect
        public var guideY: Double?
    }

    /// The versioned manifest written at export time.
    public struct Manifest: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var createdAt: Date
        public var includesOriginals: Bool
        public var project: ProjectSnapshot
        public var pieces: [PieceSnapshot]
        public var events: [EventSnapshot]
        public var documents: [DocumentSnapshot]
        public var references: [ReferenceSnapshot]

        public init(
            schemaVersion: Int = BackupFormat.schemaVersion,
            createdAt: Date,
            includesOriginals: Bool,
            project: ProjectSnapshot,
            pieces: [PieceSnapshot],
            events: [EventSnapshot],
            documents: [DocumentSnapshot],
            references: [ReferenceSnapshot]
        ) {
            self.schemaVersion = schemaVersion
            self.createdAt = createdAt
            self.includesOriginals = includesOriginals
            self.project = project
            self.pieces = pieces
            self.events = events
            self.documents = documents
            self.references = references
        }
    }

    /// A validated snapshot plus the PDF copies accepted from staging.
    public struct ValidatedRestore: Sendable {
        public let manifest: Manifest
        /// Document ID → validated staged PDF bytes.
        public let documentBytes: [UUID: Data]
    }

    // MARK: - Path policy

    /// A relative path is only acceptable when it is a plain `a/b/c` style
    /// path: no leading slash, no backslash, no empty/dot/dot-dot component.
    public static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        for component in components where component.isEmpty || component == "." || component == ".." {
            return false
        }
        return true
    }

    // MARK: - Lowercase hex SHA-256 (pure byte function, testable everywhere)

    public static func lowercaseHexDigest(_ bytes: [UInt8]) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return SHA256Lite.hash(bytes).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    // MARK: - Validation (fail closed)

    /// Validate a decoded manifest plus the staged files it references.
    /// `manifest` is the already-parsed JSON; `stagedDirectory` is the
    /// quarantine directory the staged copy lives in.
    ///
    /// Checks, all required before anything becomes durable:
    /// schema version, ID/path uniqueness, reference integrity, row
    /// count + history consistency, per-file kind (regular, non-symlink),
    /// declared size, SHA-256 match, combined-size cap.
    public static func validate(
        manifest: Manifest,
        stagedDirectory: URL,
        fileManager fm: FileManager = .default
    ) throws -> ValidatedRestore {
        guard manifest.schemaVersion >= minimumSupportedVersion else {
            throw BackupError.malformedManifest
        }
        guard manifest.schemaVersion <= schemaVersion else {
            throw BackupError.schemaTooNew(version: manifest.schemaVersion)
        }

        // --- Unique IDs -----------------------------------------------------
        var seenPieceIDs: Set<UUID> = []
        for piece in manifest.pieces where !seenPieceIDs.insert(piece.id).inserted {
            throw BackupError.duplicateID(kind: "piece", id: piece.id.uuidString)
        }
        var seenEventIDs: Set<UUID> = []
        for event in manifest.events where !seenEventIDs.insert(event.id).inserted {
            throw BackupError.duplicateID(kind: "row event", id: event.id.uuidString)
        }
        var seenDocumentIDs: Set<UUID> = []
        for document in manifest.documents where !seenDocumentIDs.insert(document.id).inserted {
            throw BackupError.duplicateID(kind: "document", id: document.id.uuidString)
        }
        var seenReferencePieces: Set<UUID> = []
        for reference in manifest.references where !seenReferencePieces.insert(reference.pieceID).inserted {
            throw BackupError.duplicateID(kind: "reference state", id: reference.pieceID.uuidString)
        }

        // --- Project + reference integrity ---------------------------------
        for piece in manifest.pieces where piece.projectID != manifest.project.id {
            throw BackupError.danglingReference(kind: "project", id: piece.projectID.uuidString)
        }
        for document in manifest.documents where document.projectID != manifest.project.id {
            throw BackupError.danglingReference(kind: "project", id: document.projectID.uuidString)
        }
        for event in manifest.events where !seenPieceIDs.contains(event.pieceID) {
            throw BackupError.danglingReference(kind: "piece", id: event.pieceID.uuidString)
        }
        for event in manifest.events {
            if event.kind == .undo, let undone = event.undoneEventID, !seenEventIDs.contains(undone) {
                throw BackupError.danglingReference(kind: "row event", id: undone.uuidString)
            }
        }
        for reference in manifest.references {
            guard seenPieceIDs.contains(reference.pieceID) else {
                throw BackupError.danglingReference(kind: "piece", id: reference.pieceID.uuidString)
            }
            if let documentID = reference.documentID, !seenDocumentIDs.contains(documentID) {
                throw BackupError.danglingReference(kind: "document", id: documentID.uuidString)
            }
        }

        // --- Row count / history consistency --------------------------------
        var eventsByPiece: [UUID: [EventSnapshot]] = [:]
        for event in manifest.events { eventsByPiece[event.pieceID, default: []].append(event) }
        for piece in manifest.pieces {
            guard RowArithmetic.isValid(completedRows: piece.completedRows),
                  RowArithmetic.isValid(repeatLength: piece.repeatLength)
            else {
                throw BackupError.invalidCountOrHistory(detail: "piece \(piece.name.prefix(20)) has out-of-range count or repeat length")
            }
            // Deterministic ordering matches RowReducer.orderedHistory
            // (sequence first, createdAt tiebreak) without requiring the
            // pure snapshot type to be the domain `RowEvent`.
            let events = (eventsByPiece[piece.id] ?? []).sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.createdAt < $1.createdAt
            }
            // Dense sequences 1...n in the ordered view.
            for (index, event) in events.enumerated() where event.sequence != index + 1 {
                throw BackupError.invalidCountOrHistory(detail: "piece \(piece.name.prefix(20)) history is not a dense sequence")
            }
            for event in events {
                guard event.kind == .repeatLengthChange || event.before != event.after else {
                    throw BackupError.invalidCountOrHistory(detail: "piece \(piece.name.prefix(20)) has a count-changing event with no change")
                }
            }
            // Replay: final event's `after` must equal the declared count.
            if let last = events.last, last.after != piece.completedRows {
                throw BackupError.invalidCountOrHistory(detail: "piece \(piece.name.prefix(20)) count does not match its history")
            }
            // Undo references must name an earlier, count-carrying event.
            for event in events where event.kind == .undo {
                let undoOK: Bool
                if let undoneID = event.undoneEventID,
                   let target = events.first(where: { $0.id == undoneID }) {
                    undoOK = target.sequence < event.sequence
                        && (target.kind == RowEventKind.completeRow || target.kind == RowEventKind.correction)
                } else {
                    undoOK = false
                }
                guard undoOK else {
                    throw BackupError.invalidCountOrHistory(detail: "piece \(piece.name.prefix(20)) has an undo that reverses nothing valid")
                }
            }
        }

        // --- Path policy for the whole manifest ------------------------------
        // Path validity + uniqueness are manifest-level checks and run
        // BEFORE any per-file inspection, so a duplicated or hostile path is
        // refused even when the referenced file is also missing.
        var declaredPaths: Set<String> = []
        for document in manifest.documents {
            let relative = document.relativePath
            guard isValidRelativePath(relative) else {
                throw relative.contains("..")
                    ? BackupError.traversalPath(entry: relative)
                    : BackupError.absolutePath(entry: relative)
            }
            guard declaredPaths.insert(relative).inserted else {
                throw BackupError.duplicatePath(entry: relative)
            }
            guard document.fileSize >= 0 else {
                throw BackupError.sizeMismatch(entry: relative)
            }
        }

        // --- Staged files ----------------------------------------------------
        var acceptedBytes: [UUID: Data] = [:]
        var totalBytes = 0
        for document in manifest.documents {
            let relative = document.relativePath

            // Full backups store PDFs *flat* under originals/ by leaf name
            // (manifest relative paths are app-internal and need not mirror
            // the backup layout).
            let leaf = relative.components(separatedBy: "/").last ?? relative
            guard isValidRelativePath(leaf) else {
                throw BackupError.traversalPath(entry: relative)
            }
            let url = stagedDirectory
                .appendingPathComponent(originalsDirectoryName, isDirectory: true)
                .appendingPathComponent(leaf, isDirectory: false)

            // Compare against the *resolved* staging root: this catches a
            // symlinked `originals/` directory or intermediate component,
            // while tolerating OS-level symlinks above the staging root
            // (e.g. /var → /private/var in test temp dirs).
            let resolvedStaged = stagedDirectory.resolvingSymlinksInPath()
            let expectedPath = resolvedStaged
                .appendingPathComponent(originalsDirectoryName, isDirectory: true)
                .appendingPathComponent(leaf, isDirectory: false)
                .standardizedFileURL.path
            let leafResolvesThroughSymlink = url.resolvingSymlinksInPath().standardizedFileURL.path != expectedPath
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
            } catch {
                throw BackupError.missingFile(entry: relative)
            }
            guard values.isSymbolicLink != true, !leafResolvesThroughSymlink else {
                throw BackupError.symlink(entry: relative)
            }
            guard values.isRegularFile == true else {
                throw BackupError.notRegularFile(entry: relative)
            }
            let actualSize = values.fileSize ?? 0
            guard actualSize == document.fileSize else {
                throw BackupError.sizeMismatch(entry: relative)
            }
            totalBytes += actualSize
            guard totalBytes <= maximumTotalBytes else {
                throw BackupError.oversizedTotal(byteCount: totalBytes)
            }

            guard let bytes = try? Data(contentsOf: url) else {
                throw BackupError.missingFile(entry: relative)
            }
            let hex = lowercaseHexDigest([UInt8](bytes))
            let expected = document.sha256.lowercased()
            guard expected.count == 64, hex == expected else {
                throw BackupError.hashMismatch(entry: relative)
            }
            acceptedBytes[document.id] = bytes
        }
        return ValidatedRestore(manifest: manifest, documentBytes: acceptedBytes)
    }

    // MARK: - ID remapping (import as a *new* project)

    /// Deterministically rebuild a validated snapshot under fresh IDs.
    /// `projectID`/`pieceID`/`documentID` scalars, undo links, and reference
    /// bindings all move through the same map, and viewport state is clamped
    /// against the (possibly different) restored page counts.
    public static func remap(_ validated: ValidatedRestore, newIDs: @Sendable () -> UUID) -> ProjectSnapshotBundle {
        let manifest = validated.manifest
        var map: [UUID: UUID] = [:]
        func mapped(_ id: UUID) -> UUID {
            if let existing = map[id] { return existing }
            let fresh = newIDs()
            map[id] = fresh
            return fresh
        }

        let project = ProjectSnapshot(
            id: mapped(manifest.project.id),
            title: manifest.project.title,
            createdAt: manifest.project.createdAt,
            updatedAt: manifest.project.updatedAt
        )
        let pieces = manifest.pieces.map { piece in
            PieceSnapshot(
                id: mapped(piece.id),
                projectID: mapped(piece.projectID),
                name: piece.name,
                completedRows: piece.completedRows,
                repeatLength: piece.repeatLength,
                notes: piece.notes
            )
        }
        let events = manifest.events.map { event in
            EventSnapshot(
                id: mapped(event.id),
                pieceID: mapped(event.pieceID),
                sequence: event.sequence,
                kind: event.kind,
                before: event.before,
                after: event.after,
                createdAt: event.createdAt,
                undoneEventID: event.undoneEventID.map { mapped($0) }
            )
        }
        // Page counts keyed by the *original* IDs, so viewport clamping can
        // run before IDs are swapped.
        let pageCountByOriginalID: [UUID: Int] = Dictionary(
            uniqueKeysWithValues: manifest.documents.map { ($0.id, $0.pageCount) }
        )
        let documents = manifest.documents.map { document -> DocumentSnapshot in
            let newID = mapped(document.id)
            // Restored copies get their OWN generated filenames: the source
            // project and the restored project must never share a physical
            // file (deletion ownership must stay one-record-one-file).
            let newLeaf = "RowCompanionImported/\(newIDs().uuidString).pdf"
            return DocumentSnapshot(
                id: newID,
                projectID: mapped(document.projectID),
                relativePath: newLeaf,
                sha256: document.sha256,
                pageCount: document.pageCount,
                fileSize: document.fileSize
            )
        }
        let references = manifest.references.map { reference in
            let clamped = ViewportClamp.clamp(
                ReferenceState(
                    pieceID: reference.pieceID,
                    documentID: reference.documentID,
                    pageIndex: reference.pageIndex,
                    visibleRect: reference.visibleRect,
                    guideY: reference.guideY
                ),
                pageCount: reference.documentID.flatMap { pageCountByOriginalID[$0] } ?? 0
            )
            return ReferenceSnapshot(
                pieceID: mapped(reference.pieceID),
                documentID: reference.documentID.map { mapped($0) },
                pageIndex: clamped.pageIndex,
                visibleRect: clamped.visibleRect,
                guideY: clamped.guideY
            )
        }
        let bytes = Dictionary(uniqueKeysWithValues: validated.documentBytes.map { (mapped($0.key), $0.value) })
        return ProjectSnapshotBundle(
            manifest: Manifest(
                schemaVersion: manifest.schemaVersion,
                createdAt: manifest.createdAt,
                includesOriginals: manifest.includesOriginals,
                project: project,
                pieces: pieces,
                events: events,
                documents: documents,
                references: references
            ),
            documentBytes: bytes
        )
    }
}

/// A remapped snapshot ready to be inserted as a brand-new project.
public struct ProjectSnapshotBundle: Sendable {
    public let manifest: BackupFormat.Manifest
    /// PDF bytes keyed by the *new* document IDs.
    public let documentBytes: [UUID: Data]

    public init(manifest: BackupFormat.Manifest, documentBytes: [UUID: Data]) {
        self.manifest = manifest
        self.documentBytes = documentBytes
    }
}

#if !canImport(CryptoKit)
/// Minimal SHA-256 used only on hosts without CryptoKit (Linux verification
/// container). On iOS the `canImport(CryptoKit)` branch above is used.
enum SHA256Lite {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        var w = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(padded[base]) << 24) | (UInt32(padded[base + 1]) << 16)
                     | (UInt32(padded[base + 2]) << 8) | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out: [UInt8] = []
        for word in h {
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8((word >> UInt32(shift)) & 0xff))
            }
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
#endif
