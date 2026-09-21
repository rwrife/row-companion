import Foundation
import CryptoKit
import PDFKit

/// Every way a PDF import can be refused, with copy suitable for an alert.
/// All cases happen **before** anything becomes durable — a rejection never
/// leaves a partial record or a stray file behind.
public enum PDFImportError: Error, Equatable, Sendable {
    /// File is (or claims to be) larger than the 50 MiB pre-flight limit.
    case oversizedFile(byteCount: Int)
    /// PDFKit cannot parse the file at all (corrupt / not a PDF).
    case notAValidPDF
    /// Document is password-locked; unsupported in MVP.
    case passwordProtected
    /// Parsed but contains zero pages.
    case zeroPageDocument
    /// More than the 500-page pre-flight limit.
    case tooManyPages(pageCount: Int)
    /// Copy/read/parse IO failed (disk full, permission, vanished file).
    case storageFailure(underlying: String)
    /// The app-owned copy on disk no longer matches its recorded hash.
    case integrityMismatch

    public var userMessage: String {
        switch self {
        case .oversizedFile(let bytes):
            return "This PDF is too large (\(ByteCount.Format.mebibytes(bytes))). The limit is \(ByteCount.Format.mebibytes(PDFImport.maximumBytes))."
        case .notAValidPDF:
            return "This file could not be opened as a PDF. It may be corrupt or not a PDF."
        case .passwordProtected:
            return "Password-protected PDFs are not supported. Remove the password and try again."
        case .zeroPageDocument:
            return "This PDF has no pages."
        case .tooManyPages(let count):
            return "This PDF has \(count) pages; the limit is \(PDFImport.maximumPages)."
        case .storageFailure:
            return "The pattern could not be saved. Check available storage and try again."
        case .integrityMismatch:
            return "The stored pattern failed its integrity check and was removed."
        }
    }
}

/// Non-UI formatting helper so error copy stays testable off-device.
public enum ByteCount {
    public enum Format {
        public static func mebibytes(_ bytes: Int) -> String {
            let mib = Double(bytes) / (1024 * 1024)
            return mib >= 1
                ? String(format: "%.1f MiB", mib)
                : String(format: "%.0f KiB", Double(bytes) / 1024)
        }
    }
}

/// Bounded PDF importer (PLAN.md "Import / export / ownership boundary").
///
/// Pipeline, in order of increasing cost, with hard limits enforced as early
/// as possible:
/// 1. `startAccessingSecurityScopedResource()` on the picked URL; the
///    balancing `stop` always runs (defer).
/// 2. File-size pre-flight against the 50 MiB cap **before** reading bytes.
/// 3. Copy to a staging file with a generated UUID name under
///    `Application Support/RowCompanion/documents/` — the app never trusts or
///    keeps the source filename, and never mutates the source.
/// 4. Parse the staged copy (not the source) with PDFKit; reject locked,
///    invalid, zero-page, and >500-page documents.
/// 5. Hash the staged copy, then move it into its final generated path.
///
/// Any failure after staging deletes the staged file, so a rejected import
/// can never leave a partial record or orphaned bytes. PDF links inside the
/// document are never followed by this code path (the viewer disables
/// selection/link following — see `RowPDFView`).
public enum PDFImport {
    /// Hard pre-flight caps from PLAN.md ("at most 50 MiB and 500 pages").
    public static let maximumBytes = 50 * 1024 * 1024
    public static let maximumPages = 500

    public struct Accepted: Sendable {
        /// Generated ID used for the app-owned filename.
        public let documentID: UUID
        /// SHA-256 (lowercase hex) of the imported bytes.
        public let sha256: String
        public let pageCount: Int
        /// Filename of the durable app-owned copy, e.g. `<uuid>.pdf`.
        public let storedFileName: String
    }

    /// Directory layout: documents live beside the store inside Application
    /// Support so file protection follows the device lock policy.
    public static func documentsDirectory(storeURL: URL) -> URL {
        let base = storeURL
            .deletingLastPathComponent()   // .../Application Support/RowCompanion (or test temp dir)
            .appendingPathComponent("RowCompanionImported", isDirectory: true)
        return base
    }

    /// Import `sourceURL` into a generated app-owned filename.
    /// - Throws: `PDFImportError` — and on **every** throw, no staged bytes
    ///   remain on disk.
    @MainActor
    public static func performImport(sourceURL: URL, storeURL: URL) throws -> Accepted {
        // (1) Security-scoped access, always balanced.
        let secured = sourceURL.startAccessingSecurityScopedResource()
        defer { if secured { sourceURL.stopAccessingSecurityScopedResource() } }

        // (2) Cheap size pre-flight before any allocation or copy.
        let attrs: URLResourceValues
        do {
            attrs = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        } catch {
            throw PDFImportError.storageFailure(underlying: String(describing: error))
        }
        let size = attrs.fileSize ?? 0
        guard attrs.isRegularFile == true else { throw PDFImportError.notAValidPDF }
        guard size <= maximumBytes else { throw PDFImportError.oversizedFile(byteCount: size) }

        // Staging target with a generated name — never the source filename.
        let directory = documentsDirectory(storeURL: storeURL)
        let documentID = UUID()
        let stagedURL = directory.appendingPathComponent("staging-\(documentID.uuidString).pdf")
        let finalURL = directory.appendingPathComponent("\(documentID.uuidString).pdf")

        return try stagedImport(
            sourceURL: sourceURL,
            finalURL: finalURL,
            stagedURL: stagedURL,
            directory: directory,
            documentID: documentID
        )
    }

    /// Split out so tests can inject an IO failure at the final move step and
    /// prove nothing durable survives. Production callers use `performImport`.
    /// MainActor-isolated (like `performImport`) so the hook is process-safe
    /// mutable state under Swift 6 strict concurrency.
    @MainActor static var testHookBeforeFinalMove: (() throws -> Void)?

    @MainActor
    private static func stagedImport(
        sourceURL: URL,
        finalURL: URL,
        stagedURL: URL,
        directory: URL,
        documentID: UUID
    ) throws -> Accepted {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            throw PDFImportError.storageFailure(underlying: String(describing: error))
        }

        defer { try? fm.removeItem(at: stagedURL) }   // always runs; final URL was moved out first

        // (3) Copy to staging. `copyItem` keeps the source untouched.
        do {
            try fm.copyItem(at: sourceURL, to: stagedURL)
        } catch {
            throw PDFImportError.storageFailure(underlying: String(describing: error))
        }

        // Post-copy size re-check: the file could have grown between pre-flight
        // and copy; enforce the cap on the bytes we actually hold.
        do {
            let stagedSize = try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard stagedSize <= maximumBytes else {
                throw PDFImportError.oversizedFile(byteCount: stagedSize)
            }
        } catch let error as PDFImportError {
            throw error
        } catch {
            throw PDFImportError.storageFailure(underlying: String(describing: error))
        }

        // (4) Parse the staged copy. Opening from *data we own* guarantees the
        // source is never mutated or re-read behind our back.
        guard let data = try? Data(contentsOf: stagedURL, options: [.mappedIfSafe]) else {
            throw PDFImportError.storageFailure(underlying: "unreadable staged copy")
        }
        guard let pdf = PDFDocument(data: data) else {
            // A locked document cannot be opened without its password and
            // fails the same initializer; distinguish it from garbage bytes
            // by the presence of the encryption dictionary marker in the
            // trailer so the UI can say "remove the password" instead of
            // "file is corrupt". Fail-closed: the marker always rejects.
            throw Self.classifyUnopenable(data)
        }
        if pdf.isEncrypted {
            throw PDFImportError.passwordProtected
        }
        let pageCount = pdf.pageCount
        guard pageCount > 0 else { throw PDFImportError.zeroPageDocument }
        guard pageCount <= maximumPages else { throw PDFImportError.tooManyPages(pageCount: pageCount) }

        // (5) Hash, then move to the final generated name.
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        if let hook = testHookBeforeFinalMove {
            do { try hook() } catch {
                throw PDFImportError.storageFailure(underlying: String(describing: error))
            }
        }
        do {
            if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
            try fm.moveItem(at: stagedURL, to: finalURL)
        } catch {
            throw PDFImportError.storageFailure(underlying: String(describing: error))
        }

        return Accepted(
            documentID: documentID,
            sha256: hex,
            pageCount: pageCount,
            storedFileName: finalURL.lastPathComponent
        )
    }

    /// Classify bytes that `PDFDocument(data:)` refused: a trailer containing
    /// an `/Encrypt` marker means password-locked (actionable message);
    /// anything else is treated as invalid. Fail-closed either way.
    static func classifyUnopenable(_ data: Data) -> PDFImportError {
        data.range(of: Data("/Encrypt".utf8)) != nil
            ? .passwordProtected
            : .notAValidPDF
    }

    /// Re-verify an existing stored document against its recorded hash before
    /// the viewer opens it; a mismatch removes the corrupt app-owned copy.
    public static func verify(storedFileURL: URL, expectedSHA256: String) throws {
        guard let data = try? Data(contentsOf: storedFileURL) else {
            throw PDFImportError.integrityMismatch
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hex == expectedSHA256 else {
            try? FileManager.default.removeItem(at: storedFileURL)
            throw PDFImportError.integrityMismatch
        }
    }
}
