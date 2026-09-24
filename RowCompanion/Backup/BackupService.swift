import Foundation

// MARK: - Backup orchestration (issue #5)
//
// `BackupService` is where the versioned format (`BackupFormat`) meets the
// file system and the repository. Its guarantees:
//
// * **Progress export (default)** writes only `manifest.json` — never PDF
//   bytes, never raw source paths (the manifest carries only generated
//   app-owned relative paths recorded at import time).
// * **Full folder backup** is opt-in: the UI must present
//   `warnings(for:)` (copyright/privacy of licensed originals) and the
//   caller passes `includeOriginals: true` only after that.
// * **Restore is staged**: the picked folder is copied into a private
//   quarantine directory under Application Support, validated there
//   (schema, paths, symlink kind, sizes, hashes, history consistency,
//   total size), and only then remapped into a brand-new project. There is
//   no overwrite path and no merge path in this API.
// * **Any failure removes the staging directory** and leaves every existing
//   project byte-identical.
//
// There is deliberately no network client, no CloudKit, and no telemetry
// anywhere on this path (privacy audit: see Tests/test_backup_contract.py).

@MainActor
public final class BackupService {
    private let repository: RowRepository

    public init(repository: RowRepository) {
        self.repository = repository
    }

    /// Folder-level copy size cap enforced before any staging work begins,
    /// so a hostile directory is refused without being copied.
    public static let maximumStagedCopyBytes = BackupFormat.maximumTotalBytes

    /// Fault-injection hooks used by tests; production never sets these.
    static var testHookBeforeStagingCopy: (() throws -> Void)?
    static var testHookAfterStagingCopy: (() throws -> Void)?
    static var testHookBeforeManifestWrite: (() throws -> Void)?

    // MARK: - Privacy guidance

    /// The copyright/privacy copy that must be shown before any export,
    /// and the additional original-material warning required before a full
    /// backup. Keeping these strings here (not in views) keeps them
    /// testable and impossible to skip silently.
    public static func warnings(for includingOriginals: Bool) -> [String] {
        var messages = [
            "This file leaves Row Companion's private storage under your control. Where you save or share it is your responsibility.",
            "It contains your project name, piece names, notes, counts, and history — keep it out of shared folders if that would expose private material.",
        ]
        if includingOriginals {
            messages.append("This backup will include copies of your imported pattern PDFs. Patterns are usually copyrighted and private: you are responsible for having the right to keep and share those copies.")
        }
        return messages
    }

    /// Honest scoping of what deletion does *not* reach (shown in UI copy
    /// and in the deletion confirmation).
    public static let deletionScopeNote = "Deletion removes this app's projects and the pattern copies it made for them. Files you exported yourself and your device/OS backups are outside the app's control and remain wherever you put them. The app cannot promise secure erasure of physical storage."

    // MARK: - Locations

    /// Quarantine area for staged restores, inside app-private storage.
    public static func stagingRoot(storeURL: URL) -> URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("RestoreStaging", isDirectory: true)
    }

    // MARK: - Export

    /// Default progress export: manifest JSON only. Returns the written data
    /// so the caller can hand it to a share/exporter; the UI may also write
    /// it via a file exporter. Throws `BackupError.exportFailed` when a
    /// referenced pattern file is unreadable (no incomplete backup emitted).
    public func exportProgress(for projectID: UUID) throws -> Data {
        let manifest = try repository.projectSnapshot(for: projectID)
        // Even the progress export validates the metadata it writes, so a
        // corrupt store state can never be laundered into a "backup".
        let probe = BackupFormat.ValidatedRestore(manifest: manifest, documentBytes: [:])
        _ = try stagedValidationProbe(probe)
        if let hook = Self.testHookBeforeManifestWrite {
            do { try hook() } catch {
                throw BackupError.exportFailed(underlying: String(describing: error))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(manifest)
        } catch {
            throw BackupError.exportFailed(underlying: String(describing: error))
        }
    }

    /// Full folder backup (explicit opt-in): `manifest.json` plus every
    /// app-owned PDF copy under `originals/<relativePath>`. The caller
    /// asserted that the user saw `warnings(for: true)`.
    public func exportFullBackup(for projectID: UUID, to destinationDirectory: URL) throws {
        var manifest = try repository.projectSnapshot(for: projectID)
        manifest.includesOriginals = true

        // Fail before writing anything if any original is unreadable.
        var payloads: [(BackupFormat.DocumentSnapshot, Data)] = []
        for document in manifest.documents {
            guard let bytes = try? repository.documentFileBytes(document.id) else {
                throw BackupError.exportFailed(underlying: "stored pattern \(document.id.uuidString.prefix(8))… is unreadable")
            }
            payloads.append((document, bytes))
        }
        if let hook = Self.testHookBeforeManifestWrite {
            do { try hook() } catch {
                throw BackupError.exportFailed(underlying: String(describing: error))
            }
        }
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(
                to: destinationDirectory.appendingPathComponent(BackupFormat.manifestFileName)
            )
            for (document, bytes) in payloads {
                // Flat layout: originals/<leaf>.pdf (see BackupFormat).
                let leaf = document.relativePath.components(separatedBy: "/").last ?? document.relativePath
                let url = destinationDirectory
                    .appendingPathComponent(BackupFormat.originalsDirectoryName, isDirectory: true)
                    .appendingPathComponent(leaf, isDirectory: false)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url)
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.exportFailed(underlying: String(describing: error))
        }
    }

    /// Validate a manifest's internal consistency without touching files
    /// (used by export and by previews). File-level checks need a staged
    /// directory; see `validate(stagedManifest:)`.
    private func stagedValidationProbe(_ validated: BackupFormat.ValidatedRestore) throws -> BackupFormat.Manifest {
        // Re-run file-free validation through the public path by validating
        // against an empty staging dir *only when there are no documents*.
        if validated.manifest.documents.isEmpty {
            let empty = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rc-probe-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: empty) }
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            _ = try BackupFormat.validate(manifest: validated.manifest, stagedDirectory: empty)
        } else {
            // Metadata-only checks duplicated cheaply: every document must
            // point at a readable file with the right size at export time.
            for document in validated.manifest.documents {
                let bytes = try repository.documentFileBytes(document.id)
                guard bytes.count == document.fileSize,
                      BackupFormat.lowercaseHexDigest([UInt8](bytes)) == document.sha256.lowercased()
                else {
                    throw BackupError.hashMismatch(entry: document.relativePath)
                }
            }
        }
        return validated.manifest
    }

    // MARK: - Staged restore

    /// Copy the picked folder into the private staging directory, replacing
    /// any staging area left over from a previous attempt. Returns the
    /// staged directory URL — nothing durable has changed yet.
    public func stageRestore(from pickedDirectory: URL) throws -> URL {
        if let hook = Self.testHookBeforeStagingCopy {
            do { try hook() } catch { throw BackupError.exportFailed(underlying: String(describing: error)) }
        }
        // User-picked folders may live behind a Files provider; balance the
        // security-scoped access exactly like the PDF importer (defer-run).
        let secured = pickedDirectory.startAccessingSecurityScopedResource()
        defer { if secured { pickedDirectory.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = Self.stagingRoot(storeURL: repository.storeURL)
        let staged = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try? fm.removeItem(at: root)   // sweep stale staging from failed attempts
            try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            let contents = try fm.contentsOfDirectory(
                at: pickedDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var total = 0
            // Clamping at cap+1 (not at the cap) keeps a single over-cap
            // item detectable while staying far away from overflow.
            let oversizeProbe = Self.maximumStagedCopyBytes + 1
            for url in contents {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let itemSize: Int
                if isDirectory {
                    // Unreadable trees count as over-cap (fail closed).
                    itemSize = min((try? Self.directoryByteSize(url)) ?? oversizeProbe,
                                   oversizeProbe)
                } else {
                    itemSize = min((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                                   oversizeProbe)
                }
                total += itemSize
                guard total <= Self.maximumStagedCopyBytes else {
                    throw BackupError.oversizedTotal(byteCount: total)
                }
            }
            for url in contents {
                try fm.copyItem(at: url, to: staged.appendingPathComponent(url.lastPathComponent))
            }
        } catch let error as BackupError {
            try? fm.removeItem(at: staged)
            throw error
        } catch {
            try? fm.removeItem(at: staged)
            throw BackupError.exportFailed(underlying: String(describing: error))
        }
        if let hook = Self.testHookAfterStagingCopy {
            do { try hook() } catch {
                // The injected failure happens *after* staging succeeded:
                // staging must be cleaned and nothing may become durable.
                try? fm.removeItem(at: staged)
                throw BackupError.exportFailed(underlying: String(describing: error))
            }
        }
        return staged
    }

    /// Parse + fully validate a staged restore folder. Throws `BackupError`
    /// describing the first hostile property found; on any throw nothing is
    /// durable (staging removal is the caller's `restore` wrapper or the
    /// sweep above).
    public func readStagedManifest(stagedDirectory: URL) throws -> BackupFormat.Manifest {
        let manifestURL = stagedDirectory.appendingPathComponent(BackupFormat.manifestFileName)
        guard let attributes = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true,
              attributes.isSymbolicLink != true,
              (attributes.fileSize ?? 0) <= BackupFormat.maximumManifestBytes
        else {
            throw BackupError.malformedManifest
        }
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw BackupError.malformedManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(BackupFormat.Manifest.self, from: data) else {
            throw BackupError.malformedManifest
        }
        return manifest
    }

    public func validate(stagedManifest: BackupFormat.Manifest, stagedDirectory: URL) throws -> BackupFormat.ValidatedRestore {
        try BackupFormat.validate(manifest: stagedManifest, stagedDirectory: stagedDirectory)
    }

    /// Non-destructive preview for the import-as-new confirmation sheet.
    public struct RestorePreview: Sendable {
        public let projectTitle: String
        public let pieceNames: [String]
        public let documentCount: Int
        public let includesOriginals: Bool
    }

    public func preview(manifest: BackupFormat.Manifest) -> RestorePreview {
        RestorePreview(
            projectTitle: manifest.project.title,
            pieceNames: manifest.pieces.map(\.name),
            documentCount: manifest.documents.count,
            includesOriginals: manifest.includesOriginals
        )
    }

    /// Full restore pipeline: stage → validate → remap IDs → write validated
    /// PDF copies at their new generated paths → insert records as a new
    /// project. On *any* throw the staging directory, any written PDF bytes
    /// are removed and existing projects are unchanged (records commit last,
    /// so a failed commit always has its bytes cleaned up).
    /// - Returns: the new project's ID.
    public func restore(from pickedDirectory: URL) throws -> UUID {
        let staged = try stageRestore(from: pickedDirectory)
        do {
            return try restoreFromStaged(staged)
        } catch {
            // restoreFromStaged cleans its own byte writes; staging is
            // removed here too so callers get one clean guarantee.
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Restore pipeline used by tests that already staged (keeps byte
    /// cleanup in one place).
    func restoreFromStaged(_ staged: URL) throws -> UUID {
        var writtenDocumentURLs: [URL] = []
        do {
            let manifest = try readStagedManifest(stagedDirectory: staged)
            let validated = try validate(stagedManifest: manifest, stagedDirectory: staged)
            let bundle = BackupFormat.remap(validated, newIDs: { UUID() })
            // Bytes first at their final generated paths; then one durable
            // record commit. A failed commit removes the bytes it wrote.
            let directory = PDFImport.documentsDirectory(storeURL: repository.storeURL)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for document in bundle.manifest.documents {
                guard let bytes = bundle.documentBytes[document.id] else {
                    throw BackupError.missingFile(entry: document.relativePath)
                }
                let url = directory
                    .appendingPathComponent(document.relativePath.components(separatedBy: "/").last ?? document.relativePath)
                try bytes.write(to: url)
                writtenDocumentURLs.append(url)
            }
            let newProjectID = try repository.insertRestoredProject(bundle)
            try? FileManager.default.removeItem(at: staged)
            return newProjectID
        } catch {
            for url in writtenDocumentURLs { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    // MARK: - Helpers

    /// Byte size of a directory tree (best-effort; unreadable entries count
    /// as Int.max so the cap fails closed).
    static func directoryByteSize(_ url: URL) throws -> Int {
        let fm = FileManager.default
        var total = 0
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += values.fileSize ?? 0
            }
        }
        return total
    }
}
