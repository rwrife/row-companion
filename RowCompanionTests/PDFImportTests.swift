import XCTest
import UIKit
import PDFKit
import CryptoKit
import SwiftData
@testable import RowCompanion

/// Owns generation of original PDF fixtures (never copyrighted material)
/// and asserts the bounded importer's guarantees end to end.
@MainActor
final class PDFImportTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("store/rowcompanion.sqlite")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        PDFImport.testHookBeforeFinalMove = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixture generation (original, generated PDFs only)

    private func writePDF(pages: Int, fileName: String = "fixture.pdf") throws -> URL {
        let url = tempDir.appendingPathComponent(fileName)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "fixture", code: 1)
        }
        for page in 0..<pages {
            context.beginPage(mediaBox: &box)
            let text = "Original fixture page \(page)"
            (text as NSString).draw(at: CGPoint(x: 20, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            context.endPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    // MARK: - Accepting valid documents

    func testAcceptsGeneratedMultiPagePDF() throws {
        let source = try writePDF(pages: 3)
        let accepted = try PDFImport.performImport(sourceURL: source, storeURL: storeURL)
        XCTAssertEqual(accepted.pageCount, 3)
        XCTAssertEqual(accepted.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PDFImport.documentsDirectory(storeURL: storeURL)
            .appendingPathComponent(accepted.storedFileName).path))
    }

    /// Generated filename is a UUID, never the picked name, and the source
    /// bytes are untouched.
    func testUsesGeneratedFilenameAndNeverMutatesSource() throws {
        let source = try writePDF(pages: 1, fileName: "my-secret-scarf-chart.pdf")
        let before = try Data(contentsOf: source)
        let accepted = try PDFImport.performImport(sourceURL: source, storeURL: storeURL)
        XCTAssertFalse(accepted.storedFileName.contains("secret"))
        XCTAssertTrue(accepted.storedFileName.hasSuffix(".pdf"))
        let after = try Data(contentsOf: source)
        XCTAssertEqual(before, after, "importer must never mutate the user's source file")
    }

    // MARK: - Bounds and rejection, with no partial records

    func testRejectsOversizedFileBeforeCopying() throws {
        // Sparse file that *claims* to exceed the cap; the pre-flight must
        // reject on size metadata without copying or parsing it.
        let big = tempDir.appendingPathComponent("huge.pdf")
        FileManager.default.createFile(atPath: big.path, contents: Data())
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(PDFImport.maximumBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try PDFImport.performImport(sourceURL: big, storeURL: storeURL)) { error in
            guard case PDFImportError.oversizedFile? = error as? PDFImportError else {
                return XCTFail("expected oversizedFile, got \(error)")
            }
        }
        // Nothing staged/durable.
        let dir = PDFImport.documentsDirectory(storeURL: storeURL)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "rejected import must leave no files: \(leftovers)")
    }

    func testRejectsGarbageAsInvalidPDF() throws {
        let junk = tempDir.appendingPathComponent("junk.pdf")
        try Data("this is not a pdf at all".utf8).write(to: junk)
        XCTAssertThrowsError(try PDFImport.performImport(sourceURL: junk, storeURL: storeURL)) { error in
            guard case PDFImportError.notAValidPDF? = error as? PDFImportError else {
                return XCTFail("expected notAValidPDF, got \(error)")
            }
        }
    }

    func testClassifiesEncryptedBytesAsPasswordProtected() throws {
        // Fail-closed classification for PDFKit-refused bytes.
        let encrypted = Data("%PDF-1.7\n<< /Encrypt 5 0 R >>\ntrailer".utf8)
        XCTAssertEqual(PDFImport.classifyUnopenable(encrypted), .passwordProtected)
        let garbage = Data("0123456789".utf8)
        XCTAssertEqual(PDFImport.classifyUnopenable(garbage), .notAValidPDF)
    }

    func testLimitsMatchPlan() {
        XCTAssertEqual(PDFImport.maximumBytes, 50 * 1024 * 1024)
        XCTAssertEqual(PDFImport.maximumPages, 500)
    }

    /// Move-step failure (e.g. disk full at the worst moment) must leave the
    /// staged file gone and no durable record possible.
    func testFinalMoveFailureLeavesNoStagedBytes() throws {
        let source = try writePDF(pages: 2)
        struct DiskFull: Error {}
        PDFImport.testHookBeforeFinalMove = { throw DiskFull() }
        XCTAssertThrowsError(try PDFImport.performImport(sourceURL: source, storeURL: storeURL)) { error in
            guard case PDFImportError.storageFailure? = error as? PDFImportError else {
                return XCTFail("expected storageFailure, got \(error)")
            }
        }
        PDFImport.testHookBeforeFinalMove = nil
        let dir = PDFImport.documentsDirectory(storeURL: storeURL)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "staged bytes must be removed on failure: \(leftovers)")
    }

    func testIntegrityVerifyDeletesCorruptCopy() throws {
        let source = try writePDF(pages: 1)
        let accepted = try PDFImport.performImport(sourceURL: source, storeURL: storeURL)
        let storedURL = PDFImport.documentsDirectory(storeURL: storeURL)
            .appendingPathComponent(accepted.storedFileName)
        // Good first.
        XCTAssertNoThrow(try PDFImport.verify(storedFileURL: storedURL, expectedSHA256: accepted.sha256))
        // Corrupt it.
        try Data("clobbered".utf8).write(to: storedURL)
        XCTAssertThrowsError(try PDFImport.verify(storedFileURL: storedURL, expectedSHA256: accepted.sha256)) { error in
            XCTAssertEqual(error as? PDFImportError, .integrityMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path), "corrupt app-owned copy must be removed")
    }

    // MARK: - Repository integration (record written only on success)

    func testRepositoryWritesRecordOnlyAfterSuccessfulImport() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Scarf")
        let source = try writePDF(pages: 4, fileName: "pattern.pdf")
        let record = try repo.importPatternDocument(from: source, for: project.id)
        XCTAssertEqual(record.pageCount, 4)
        XCTAssertEqual(try repo.documents(in: project.id).count, 1)
        // Stored file resolves through the repository URL helper and survives
        // a "relaunch".
        let relaunched = try RowRepository.open(storeURL: storeURL)
        let records = try relaunched.documents(in: project.id)
        XCTAssertEqual(records.map(\.id), [record.id])
        XCTAssertFalse(records[0].relativePath.contains("pattern.pdf"), "relative path must be generated, not user-named")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try relaunched.documentFileURL(record.id).path))
    }

    func testFailedImportLeavesNoRecordAndNoFile() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Scarf")
        let junk = tempDir.appendingPathComponent("junk.pdf")
        try Data("nope".utf8).write(to: junk)
        XCTAssertThrowsError(try repo.importPatternDocument(from: junk, for: project.id))
        XCTAssertTrue(try repo.documents(in: project.id).isEmpty)
    }
}

extension PDFImportTests {
    func testLibraryDuplicateOwnsIndependentDocumentsAndRemappedReference() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Original")
        let piece = try repo.addPiece(to: project.id, name: "Body")
        let source = try writePDF(pages: 2)
        let document = try repo.importPatternDocument(from: source, for: project.id)
        try repo.saveReferenceState(ReferenceState(pieceID: piece.id, documentID: document.id,
            pageIndex: 1, visibleRect: .full, guideY: 0.5))
        let freshID = try repo.duplicateProject(project.id, title: "Fresh")
        let freshPiece = try XCTUnwrap(repo.pieces(in: freshID).first)
        let freshDocument = try XCTUnwrap(repo.documents(in: freshID).first)
        let freshReference = try XCTUnwrap(repo.referenceState(for: freshPiece.id))
        XCTAssertEqual(freshReference.documentID, freshDocument.id, "fresh progress still opens the copied pattern")
        XCTAssertEqual(freshReference.pageIndex, 0)
        XCTAssertEqual(freshReference.visibleRect, .full)
        XCTAssertNil(freshReference.guideY)
        let copyID = try repo.duplicateProject(project.id, title: "Copy", copyProgress: true)
        let copyDocument = try XCTUnwrap(repo.documents(in: copyID).first)
        let copyPiece = try XCTUnwrap(repo.pieces(in: copyID).first)
        let copyURL = try repo.documentFileURL(copyDocument.id)
        let originalURL = try repo.documentFileURL(document.id)
        XCTAssertNotEqual(copyURL, originalURL)
        XCTAssertNotEqual(copyDocument.id, document.id)
        XCTAssertEqual(try Data(contentsOf: copyURL), try Data(contentsOf: originalURL))
        let reference = try XCTUnwrap(repo.referenceState(for: copyPiece.id))
        XCTAssertEqual(reference.documentID, copyDocument.id)
        XCTAssertEqual(reference.pageIndex, 1)
        XCTAssertEqual(reference.guideY, 0.5)
        XCTAssertThrowsError(try repo.deleteProject(copyID, confirmed: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        try repo.deleteProject(project.id, confirmed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let reopened = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try reopened.referenceState(for: copyPiece.id)?.documentID, copyDocument.id)
    }

    func testDuplicatePreservesCurrentViewerReferenceWhenCopyingProgress() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Live Viewer")
        _ = try repo.addPiece(to: project.id, name: "Front")
        let model = WorkspaceModel(repository: repo)
        model.select(project: project.id)
        XCTAssertNotNil(model.selectedPiece)
        _ = try repo.importPatternDocument(from: writePDF(pages: 3), for: project.id)
        model.select(project: project.id)
        model.viewerMoved(pageIndex: 2, visibleRect: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        try model.captureReferenceForDuplication()
        let copyID = try repo.duplicateProject(project.id, title: "Duplicated", copyProgress: true)
        let copyPiece = try XCTUnwrap(repo.pieces(in: copyID).first)
        let copyRef = try XCTUnwrap(repo.referenceState(for: copyPiece.id))
        XCTAssertEqual(copyRef.pageIndex, 2)
        XCTAssertEqual(copyRef.visibleRect.x, 0.1, accuracy: 0.001)
    }

    func testLibraryDuplicateFailureCleansCopiedFilesAndRecords() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Original")
        _ = try repo.importPatternDocument(from: writePDF(pages: 1), for: project.id)
        let directory = PDFImport.documentsDirectory(storeURL: storeURL)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        struct Fault: Error {}
        repo.testSaveFault = { throw Fault() }
        XCTAssertThrowsError(try repo.duplicateProject(project.id, title: "Copy"))
        repo.testSaveFault = nil
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertEqual(try repo.projects().count, 1)
        XCTAssertEqual(try repo.documents(in: project.id).count, 1)
        let original = try XCTUnwrap(repo.documents(in: project.id).first)
        try FileManager.default.removeItem(at: repo.documentFileURL(original.id))
        XCTAssertThrowsError(try repo.duplicateProject(project.id, title: "Missing PDF"))
        XCTAssertEqual(try repo.projects().count, 1)
    }
}

extension PDFImportTests {
    func testDuplicateRejectsTamperedOwnedPDFsWithoutChangingSources() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Original")
        _ = try repo.importPatternDocument(from: writePDF(pages: 1), for: project.id)
        _ = try repo.importPatternDocument(from: writePDF(pages: 2), for: project.id)
        // Tamper with the last document so failure must also clean any earlier copy.
        let document = try XCTUnwrap(repo.documents(in: project.id).last)
        let source = try repo.documentFileURL(document.id)
        let original = try Data(contentsOf: source)
        let directory = source.deletingLastPathComponent()
        let context = ModelContext(repo.container)
        let documentID = document.id
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<StoredPatternDocument>(predicate: #Predicate { $0.id == documentID })).first)
        for attack in ["hash", "corrupt", "pages", "oversized", "symlink"] {
            try? FileManager.default.removeItem(at: source)
            try original.write(to: source)
            stored.sha256 = document.sha256
            stored.pageCount = document.pageCount
            switch attack {
            case "hash": try Data("tampered".utf8).write(to: source)
            case "corrupt":
                let bytes = Data("not a PDF".utf8)
                try bytes.write(to: source)
                stored.sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            case "pages": stored.pageCount = document.pageCount + 1
            case "oversized":
                let handle = try FileHandle(forWritingTo: source)
                try handle.truncate(atOffset: UInt64(PDFImport.maximumBytes + 1))
                try handle.close()
            default:
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: writePDF(pages: 1))
            }
            try context.save()
            // Use a fresh context to observe the tampered metadata.
            let fresh = try RowRepository.open(storeURL: storeURL)
            let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let bytes = attack == "oversized" ? nil : try Data(contentsOf: source)
            XCTAssertThrowsError(try fresh.duplicateProject(project.id, title: "Rejected"), attack)
            XCTAssertEqual(try fresh.projects().count, 1, attack)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before, attack)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber, attributes[.size] as? NSNumber, attack)
            if let bytes { XCTAssertEqual(try Data(contentsOf: source), bytes, attack) }
            if attack == "symlink" {
                XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: source.path))
            }
        }
    }
}
