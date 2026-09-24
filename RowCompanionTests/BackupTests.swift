import XCTest
import PDFKit
import UIKit
@testable import RowCompanion

/// Acceptance tests for issue #5: versioned export/restore, staged hostile
/// rejection, failure rollback, and app-owned-only deletion. Runs against
/// real on-disk stores and real generated PDF fixtures (original bytes only).
@MainActor
final class BackupTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("store/rowcompanion.sqlite")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        BackupService.testHookBeforeStagingCopy = nil
        BackupService.testHookAfterStagingCopy = nil
        BackupService.testHookBeforeManifestWrite = nil
    }

    override func tearDownWithError() throws {
        BackupService.testHookBeforeStagingCopy = nil
        BackupService.testHookAfterStagingCopy = nil
        BackupService.testHookBeforeManifestWrite = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

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
            let text = "Original backup fixture page \(page)"
            (text as NSString).draw(at: CGPoint(x: 20, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            context.endPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    /// A repository with one project, one repeat-aware piece with history
    /// including an undo, and one imported PDF with viewer state.
    private func makePopulatedRepository() throws -> (RowRepository, UUID, UUID, UUID) {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Backup Scarf")
        let piece = try repo.addPiece(to: project.id, name: "front", repeatLength: 8)
        try repo.apply(.completeRow, to: piece.id)
        try repo.apply(.completeRow, to: piece.id)
        try repo.apply(.undo, to: piece.id)
        try repo.setNotes("k2 p2", on: piece.id)
        let source = try writePDF(pages: 3, fileName: "chart.pdf")
        let document = try repo.importPatternDocument(from: source, for: project.id)
        try repo.saveReferenceState(ReferenceState(
            pieceID: piece.id, documentID: document.id, pageIndex: 1,
            visibleRect: NormalizedRect(x: 0, y: 0, width: 1, height: 1), guideY: 0.5
        ))
        return (repo, project.id, piece.id, document.id)
    }

    private func encode(_ manifest: BackupFormat.Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func decode(_ data: Data) throws -> BackupFormat.Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupFormat.Manifest.self, from: data)
    }

    /// Write a staged restore folder under a *different* root so validation
    /// treats it like quarantined content. Files land at
    /// `originals/<relativePath>` exactly as a full backup exports them.
    private func makeStagedFolder(manifest: BackupFormat.Manifest, files: [String: Data] = [:]) throws -> URL {
        let staged = tempDir.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged.appendingPathComponent("originals", isDirectory: true), withIntermediateDirectories: true)
        try encode(manifest).write(to: staged.appendingPathComponent(BackupFormat.manifestFileName))
        let originals = staged.appendingPathComponent("originals", isDirectory: true)
        for (relative, data) in files {
            let leaf = relative.components(separatedBy: "/").last ?? relative
            let url = originals.appendingPathComponent(leaf)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return staged
    }

    private func baseManifest() -> BackupFormat.Manifest {
        BackupFormat.Manifest(
            createdAt: Date(),
            includesOriginals: true,
            project: BackupFormat.ProjectSnapshot(id: UUID(), title: "Restored", createdAt: Date(), updatedAt: Date()),
            pieces: [], events: [], documents: [], references: []
        )
    }

    // MARK: - Manifest consistency + snapshot metadata

    func testSnapshotMetadataIncludesVersionsHashesAndSizes() throws {
        let (repo, projectID, _, documentID) = try makePopulatedRepository()
        let manifest = try repo.projectSnapshot(for: projectID)
        XCTAssertEqual(manifest.schemaVersion, BackupFormat.schemaVersion)
        let doc = try XCTUnwrap(manifest.documents.first(where: { $0.id == documentID }))
        XCTAssertEqual(doc.sha256.count, 64)
        XCTAssertGreaterThan(doc.fileSize, 0)
        XCTAssertFalse(manifest.includesOriginals, "snapshots default to progress-only")
        // History + reference captured.
        XCTAssertEqual(manifest.events.count, 3)
        XCTAssertEqual(manifest.references.first?.pageIndex, 1)
    }

    // MARK: - Default export privacy

    func testProgressExportOmitsPDFBytesAndSourcePaths() throws {
        let (repo, projectID, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        let data = try service.exportProgress(for: projectID)
        // Darwin JSONEncoder routes through NSJSONSerialization, which
        // escapes forward slashes (\/). Unescape before the path-shape scan
        // so this check sees identical shapes on every host.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertFalse(json.contains("chart.pdf"), "export must never carry the user's filename")
        XCTAssertFalse(json.contains(tempDir.path), "no raw source paths in the export")
        XCTAssertFalse(json.contains("%PDF"), "no PDF bytes in a progress export")
        // Only app-generated relative paths survive: every quoted value with
        // a slash must be under the generated import directory.
        for match in json.components(separatedBy: "\"") where match.contains("/") {
            XCTAssertTrue(match.hasPrefix("RowCompanionImported/"), "unexpected path-shaped value \(match)")
        }
        // Still round-trips as a valid manifest.
        let manifest = try decode(data)
        XCTAssertEqual(manifest.project.title, "Backup Scarf")
        XCTAssertEqual(manifest.pieces.first?.completedRows, 1)
    }

    // MARK: - Full backup + round trip into new IDs

    func testFullBackupRoundTripCreatesNewProjectWithNewIDs() throws {
        let (repo, projectID, pieceID, documentID) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        let backupDir = tempDir.appendingPathComponent("full-backup", isDirectory: true)
        try service.exportFullBackup(for: projectID, to: backupDir)

        // Manifest + originals exist; originals carry the PDF bytes.
        let manifestData = try Data(contentsOf: backupDir.appendingPathComponent(BackupFormat.manifestFileName))
        let manifest = try decode(manifestData)
        XCTAssertTrue(manifest.includesOriginals)
        let relative = try XCTUnwrap(manifest.documents.first?.relativePath)
        let leaf = relative.components(separatedBy: "/").last ?? relative
        let copied = backupDir.appendingPathComponent("originals").appendingPathComponent(leaf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "full backup nests originals flat at originals/\(leaf)")

        // Restore into the same repository: a *new* project with all-new IDs.
        let newProjectID = try service.restore(from: backupDir)
        XCTAssertNotEqual(newProjectID, projectID)
        let projects = try repo.projects()
        XCTAssertEqual(projects.count, 2, "restore never overwrites or merges")
        let restored = try repo.pieces(in: newProjectID)
        XCTAssertEqual(restored.count, 1)
        let newPiece = try XCTUnwrap(restored.first)
        XCTAssertNotEqual(newPiece.id, pieceID)
        XCTAssertEqual(newPiece.completedRows, 1)
        XCTAssertEqual(newPiece.name, "front")
        XCTAssertEqual(try repo.history(for: newPiece.id).map(\.kind), [.completeRow, .completeRow, .undo])
        let newDocs = try repo.documents(in: newProjectID)
        XCTAssertEqual(newDocs.count, 1)
        XCTAssertNotEqual(newDocs[0].id, documentID)
        // The restored document's bytes open as a 3-page PDF.
        let bytes = try Data(contentsOf: repo.documentFileURL(newDocs[0].id))
        XCTAssertEqual(PDFDocument(data: bytes)?.pageCount, 3)
        // Viewer state moved with it (page 1, guide 0.5).
        let state = try XCTUnwrap(repo.referenceState(for: newPiece.id))
        XCTAssertEqual(state.pageIndex, 1)
        XCTAssertEqual(state.guideY, 0.5)
        // Original project untouched.
        XCTAssertEqual(try repo.pieces(in: projectID).first?.completedRows, 1)
    }

    // MARK: - Hostile archive rejection

    func testRejectsFutureSchemaVersion() throws {
        let (repo, _, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        var manifest = try repo.projectSnapshot(for: try XCTUnwrap(repo.projects().first).id)
        manifest.schemaVersion = BackupFormat.schemaVersion + 5
        let staged = try makeStagedFolder(manifest: manifest)
        XCTAssertThrowsError(try service.validate(stagedManifest: try service.readStagedManifest(stagedDirectory: staged), stagedDirectory: staged)) { error in
            guard case BackupError.schemaTooNew(let v)? = error as? BackupError else { return XCTFail("got \(error)") }
            XCTAssertEqual(v, BackupFormat.schemaVersion + 5)
        }
    }

    func testRejectsTraversalPath() throws {
        let (repo, _, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        var manifest = baseManifest()
        manifest.documents = [BackupFormat.DocumentSnapshot(
            id: UUID(), projectID: manifest.project.id,
            relativePath: "RowCompanionImported/../../../../etc/passwd",
            sha256: String(repeating: "a", count: 64), pageCount: 1, fileSize: 10
        )]
        let staged = try makeStagedFolder(manifest: manifest, files: ["x": Data()] as [String: Data])
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.traversalPath? = error as? BackupError else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(BackupFormat.isValidRelativePath("RowCompanionImported/ok.pdf") == true)
        XCTAssertFalse(BackupFormat.isValidRelativePath("a/../b"))
        XCTAssertFalse(BackupFormat.isValidRelativePath("/etc/passwd"))
        XCTAssertFalse(BackupFormat.isValidRelativePath(""))
        XCTAssertFalse(BackupFormat.isValidRelativePath("a//b"))
    }

    func testRejectsAbsolutePath() throws {
        var manifest = baseManifest()
        manifest.documents = [BackupFormat.DocumentSnapshot(
            id: UUID(), projectID: manifest.project.id,
            relativePath: "/etc/passwd", sha256: String(repeating: "a", count: 64),
            pageCount: 1, fileSize: 10
        )]
        let staged = tempDir.appendingPathComponent("staged-abs", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.absolutePath? = error as? BackupError else { return XCTFail("got \(error)") }
        }
    }

    func testRejectsSymlinkEntry() throws {
        let (repo, _, _, documentID) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        var manifest = try repo.projectSnapshot(for: try XCTUnwrap(repo.projects().first).id)
        let doc = try XCTUnwrap(manifest.documents.first(where: { $0.id == documentID }))
        manifest.documents = [doc]
        let staged = tempDir.appendingPathComponent("staged-symlink-\(UUID().uuidString)", isDirectory: true)
        let originals = staged.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try encode(manifest).write(to: staged.appendingPathComponent(BackupFormat.manifestFileName))
        // Real payload the symlink points at lives OUTSIDE the staged dir.
        let outside = tempDir.appendingPathComponent("outside.pdf")
        try Data(contentsOf: repo.documentFileURL(documentID)).write(to: outside)
        let leaf = doc.relativePath.components(separatedBy: "/").last ?? doc.relativePath
        try FileManager.default.createSymbolicLink(at: originals.appendingPathComponent(leaf), withDestinationURL: outside)
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.symlink? = error as? BackupError else { return XCTFail("got \(error)") }
        }
    }

    func testRejectsDuplicateEntriesAndIDs() throws {
        var manifest = baseManifest()
        let dupPiece = BackupFormat.PieceSnapshot(id: UUID(), projectID: manifest.project.id, name: "dup", completedRows: 0, repeatLength: nil, notes: "")
        manifest.pieces = [dupPiece, dupPiece]
        let staged = tempDir.appendingPathComponent("staged-dup", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.duplicateID? = error as? BackupError else { return XCTFail("got \(error)") }
        }

        var manifest2 = baseManifest()
        let idA = UUID(), idB = UUID()
        manifest2.pieces = [
            BackupFormat.PieceSnapshot(id: idA, projectID: manifest2.project.id, name: "a", completedRows: 0, repeatLength: nil, notes: ""),
            BackupFormat.PieceSnapshot(id: idB, projectID: manifest2.project.id, name: "b", completedRows: 0, repeatLength: nil, notes: ""),
        ]
        let bytes = Data("same".utf8)
        let hex = BackupFormat.lowercaseHexDigest([UInt8](bytes))
        manifest2.documents = [
            BackupFormat.DocumentSnapshot(id: UUID(), projectID: manifest2.project.id, relativePath: "RowCompanionImported/x.pdf", sha256: hex, pageCount: 1, fileSize: bytes.count),
            BackupFormat.DocumentSnapshot(id: UUID(), projectID: manifest2.project.id, relativePath: "RowCompanionImported/x.pdf", sha256: hex, pageCount: 1, fileSize: bytes.count),
        ]
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest2, stagedDirectory: staged)) { error in
            guard case BackupError.duplicatePath? = error as? BackupError else { return XCTFail("got \(error)") }
        }
    }

    func testRejectsDanglingReferences() throws {
        var manifest = baseManifest()
        manifest.pieces = []
        manifest.events = [BackupFormat.EventSnapshot(
            id: UUID(), pieceID: UUID(), sequence: 1, kind: .completeRow,
            before: 0, after: 1, createdAt: Date(), undoneEventID: nil
        )]
        let staged = tempDir.appendingPathComponent("staged-dangling", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.danglingReference? = error as? BackupError else { return XCTFail("got \(error)") }
        }
    }

    func testRejectsInvalidCountsAndHistory() throws {
        // Count beyond the domain maximum.
        var manifest = baseManifest()
        manifest.pieces = [BackupFormat.PieceSnapshot(id: UUID(), projectID: manifest.project.id, name: "big", completedRows: RowArithmetic.maximumCompletedRows + 1, repeatLength: nil, notes: "")]
        let staged = tempDir.appendingPathComponent("staged-counts", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.invalidCountOrHistory? = error as? BackupError else { return XCTFail("got \(error)") }
        }

        // History that does not end at the declared count.
        var manifest2 = baseManifest()
        let pieceID = UUID()
        manifest2.pieces = [BackupFormat.PieceSnapshot(id: pieceID, projectID: manifest2.project.id, name: "drift", completedRows: 42, repeatLength: nil, notes: "")]
        manifest2.events = [BackupFormat.EventSnapshot(id: UUID(), pieceID: pieceID, sequence: 1, kind: .completeRow, before: 0, after: 1, createdAt: Date(), undoneEventID: nil)]
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest2, stagedDirectory: staged)) { error in
            guard case BackupError.invalidCountOrHistory? = error as? BackupError else { return XCTFail("got \(error)") }
        }

        // Gap in sequences.
        var manifest3 = baseManifest()
        manifest3.pieces = [BackupFormat.PieceSnapshot(id: pieceID, projectID: manifest3.project.id, name: "gap", completedRows: 2, repeatLength: nil, notes: "")]
        manifest3.events = [
            BackupFormat.EventSnapshot(id: UUID(), pieceID: pieceID, sequence: 1, kind: .completeRow, before: 0, after: 1, createdAt: Date(), undoneEventID: nil),
            BackupFormat.EventSnapshot(id: UUID(), pieceID: pieceID, sequence: 3, kind: .completeRow, before: 1, after: 2, createdAt: Date(), undoneEventID: nil),
        ]
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest3, stagedDirectory: staged)) { error in
            guard case BackupError.invalidCountOrHistory? = error as? BackupError else { return XCTFail("got \(error)") }
        }
    }

    func testRejectsHashMismatchAndSizeMismatch() throws {
        let (repo, _, _, documentID) = try makePopulatedRepository()
        var manifest = try repo.projectSnapshot(for: try XCTUnwrap(repo.projects().first).id)
        let doc = try XCTUnwrap(manifest.documents.first(where: { $0.id == documentID }))
        manifest.documents = [doc]
        let staged = tempDir.appendingPathComponent("staged-hash-\(UUID().uuidString)", isDirectory: true)
        let originals = staged.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try encode(manifest).write(to: staged.appendingPathComponent(BackupFormat.manifestFileName))
        let leaf = doc.relativePath.components(separatedBy: "/").last ?? doc.relativePath

        // Right size, wrong content -> hash mismatch.
        var wrong = Data(count: doc.fileSize)
        for i in wrong.indices { wrong[i] = UInt8(i % 251) }
        try wrong.write(to: originals.appendingPathComponent(leaf))
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.hashMismatch? = error as? BackupError else { return XCTFail("got \(error)") }
        }

        // Wrong size.
        try Data("tiny".utf8).write(to: originals.appendingPathComponent(leaf))
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.sizeMismatch? = error as? BackupError else { return XCTFail("got \(error)") }
        }

        // Missing file.
        try FileManager.default.removeItem(at: originals.appendingPathComponent(leaf))
        XCTAssertThrowsError(try BackupFormat.validate(manifest: manifest, stagedDirectory: staged)) { error in
            guard case BackupError.missingFile? = error as? BackupError else { return XCTFail("got \(error)") }
        }
    }

    func testOversizedTotalRejectedBeforeCopyAndInValidation() throws {
        let (repo, _, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        let bigSource = tempDir.appendingPathComponent("big-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: bigSource, withIntermediateDirectories: true)
        // The cap must be exceeded with *allocated* bytes: Darwin's
        // fileSizeKey reports allocated disk usage, so a sparse (truncated)
        // file measures ~0 there while Linux tmpfs charges full size.
        // Dense chunks accumulate the same way on both hosts and the loop
        // must refuse before copying anything.
        let chunk = Data(count: 3 * 1024 * 1024)
        let chunkCount = BackupFormat.maximumTotalBytes / chunk.count + 2
        for index in 0..<chunkCount {
            try chunk.write(to: bigSource.appendingPathComponent("blob-\(index).bin"))
        }
        XCTAssertThrowsError(try service.stageRestore(from: bigSource)) { error in
            guard case BackupError.oversizedTotal? = error as? BackupError else { return XCTFail("got \(error)") }
        }
        // Staging swept: no staged directory left behind.
        let root = BackupService.stagingRoot(storeURL: storeURL)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "failed staging must clean up: \(leftovers)")
    }

    // MARK: - Failure injection

    func testInjectedStagingFailurePreservesProjectsAndCleansStaging() throws {
        let (repo, projectID, pieceID, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        let backupDir = tempDir.appendingPathComponent("inject-backup", isDirectory: true)
        try service.exportFullBackup(for: projectID, to: backupDir)

        struct StagingFault: Error {}
        BackupService.testHookAfterStagingCopy = { throw StagingFault() }
        XCTAssertThrowsError(try service.restore(from: backupDir))
        BackupService.testHookAfterStagingCopy = nil

        // Existing project untouched, staging swept.
        XCTAssertEqual(try repo.projects().count, 1)
        XCTAssertEqual(try repo.pieces(in: projectID).first?.completedRows, 1)
        let root = BackupService.stagingRoot(storeURL: storeURL)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "staging must be removed on injected failure: \(leftovers)")

        // And a subsequent clean restore still works.
        let newID = try service.restore(from: backupDir)
        XCTAssertEqual(try repo.projects().count, 2)
        XCTAssertNotEqual(try repo.pieces(in: newID).first?.id, pieceID)
    }

    func testInjectedSaveFaultOnRestoreLeavesNoProjectAndNoOrphanBytes() throws {
        let (repo, projectID, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        let backupDir = tempDir.appendingPathComponent("savefault-backup", isDirectory: true)
        try service.exportFullBackup(for: projectID, to: backupDir)
        let docsBefore = (try? FileManager.default.contentsOfDirectory(atPath: PDFImport.documentsDirectory(storeURL: storeURL).path)) ?? []

        struct SaveFault: Error {}
        repo.testSaveFault = { throw SaveFault() }
        XCTAssertThrowsError(try service.restore(from: backupDir))
        repo.testSaveFault = nil

        XCTAssertEqual(try repo.projects().count, 1, "rolled-back restore must not leave a project")
        let docsAfter = (try? FileManager.default.contentsOfDirectory(atPath: PDFImport.documentsDirectory(storeURL: storeURL).path)) ?? []
        XCTAssertEqual(Set(docsBefore), Set(docsAfter), "rolled-back restore must not leave PDF bytes")
        let root = BackupService.stagingRoot(storeURL: storeURL)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testInjectedExportFailureProducesNoPartialFile() throws {
        let (repo, projectID, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        struct ExportFault: Error {}
        BackupService.testHookBeforeManifestWrite = { throw ExportFault() }
        XCTAssertThrowsError(try service.exportProgress(for: projectID))
        let dir = tempDir.appendingPathComponent("export-target", isDirectory: true)
        XCTAssertThrowsError(try service.exportFullBackup(for: projectID, to: dir))
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "failed export must write nothing: \(contents)")
    }

    // MARK: - Deletion

    func testDeletionRemovesOnlyAppOwnedFilesAfterConfirmation() throws {
        let (repo, doomedID, _, documentID) = try makePopulatedRepository()
        // A second project that must survive.
        let keeper = try repo.createProject(title: "Keeper")
        let keeperPiece = try repo.addPiece(to: keeper.id, name: "cuff")
        try repo.apply(.completeRow, to: keeperPiece.id)
        let doomedDocURL = try repo.documentFileURL(documentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doomedDocURL.path))
        // A file the user placed themselves inside the documents directory
        // is not app-owned (not named by any record) and must NOT be removed.
        let foreign = PDFImport.documentsDirectory(storeURL: storeURL).appendingPathComponent("user-kept-note.txt")
        try Data("mine".utf8).write(to: foreign)

        // Unconfirmed deletion removes nothing.
        XCTAssertThrowsError(try repo.deleteProject(doomedID, confirmed: false)) { error in
            guard case RowRepository.BackupRepositoryError.deletionRequiresConfirmation? = error as? RowRepository.BackupRepositoryError else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(try repo.projects().count, 2)

        try repo.deleteProject(doomedID, confirmed: true)
        let projects = try repo.projects()
        XCTAssertEqual(projects.map(\.title), ["Keeper"])
        XCTAssertTrue(try repo.pieces(in: doomedID).isEmpty)
        XCTAssertTrue(try repo.documents(in: doomedID).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomedDocURL.path), "app-owned PDF must be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "files not owned by deleted records survive")
        // Keeper data intact across a relaunch.
        let relaunched = try RowRepository.open(storeURL: storeURL)
        XCTAssertEqual(try relaunched.pieces(in: keeper.id).first?.completedRows, 1)
        XCTAssertEqual(try relaunched.history(for: keeperPiece.id).count, 1)
    }

    func testDeletionWithSaveFaultRemovesNothing() throws {
        let (repo, doomedID, _, documentID) = try makePopulatedRepository()
        let docURL = try repo.documentFileURL(documentID)
        struct SaveFault: Error {}
        repo.testSaveFault = { throw SaveFault() }
        XCTAssertThrowsError(try repo.deleteProject(doomedID, confirmed: true))
        repo.testSaveFault = nil
        XCTAssertEqual(try repo.projects().count, 1, "failed deletion must keep the project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: docURL.path), "failed deletion must keep files")
    }

    // MARK: - Warnings + remapping

    func testFullBackupWarningsMentionCopyrightAndPrivacy() throws {
        let plain = BackupService.warnings(for: false)
        let full = BackupService.warnings(for: true)
        XCTAssertTrue(full.count > plain.count, "originals opt-in adds its own warning")
        XCTAssertTrue(full.joined().contains("copyright") || full.joined().contains("Copyright"))
        XCTAssertTrue(plain.joined().lowercased().contains("responsibility"))
        XCTAssertFalse(plain.joined().contains("pattern PDFs"))
    }

    func testRemapAssignsFreshIDsAndClampsViewport() throws {
        let (repo, projectID, _, _) = try makePopulatedRepository()
        let service = BackupService(repository: repo)
        let backupDir = tempDir.appendingPathComponent("remap-backup", isDirectory: true)
        try service.exportFullBackup(for: projectID, to: backupDir)
        let staged = try service.stageRestore(from: backupDir)
        let manifest = try service.readStagedManifest(stagedDirectory: staged)
        let validated = try service.validate(stagedManifest: manifest, stagedDirectory: staged)
        // Swift 6: the ID generator is @Sendable, so its counter must be
        // concurrency-safe (the call sequence is deterministic regardless).
        let counter = DeterministicCounter()
        let bundle = BackupFormat.remap(validated, newIDs: {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter.next()))!
        })
        XCTAssertNotEqual(bundle.manifest.project.id, manifest.project.id)
        XCTAssertNotEqual(bundle.manifest.pieces[0].id, manifest.pieces[0].id)
        // Undo links follow the map.
        let undo = try XCTUnwrap(bundle.manifest.events.first(where: { $0.kind == .undo }))
        let undone = try XCTUnwrap(undo.undoneEventID)
        XCTAssertTrue(bundle.manifest.events.contains { $0.id == undone })
        XCTAssertFalse(manifest.events.contains { $0.id == undone }, "remapped undo must not reference an old ID")
        // Deterministic: same generator sequence -> same IDs.
        let counter2 = DeterministicCounter()
        let again = BackupFormat.remap(validated, newIDs: {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter2.next()))!
        })
        XCTAssertEqual(bundle.manifest, again.manifest)
    }
}

/// Sendable monotonic counter for deterministic ID generators in tests.
private final class DeterministicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 1_000
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
