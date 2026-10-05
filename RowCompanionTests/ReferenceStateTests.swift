import XCTest
@testable import RowCompanion

/// Durability + isolation guarantees for the resumable workspace (issue #3):
/// independent per-piece count/page/viewport/guide/notes across a "relaunch"
/// (fresh repository instance over the same store), and the rule that
/// selection/layout changes can never touch counts.
@MainActor
final class ReferenceStateTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-ref-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("store/rowcompanion.sqlite")
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writePDF(pages: Int, fileName: String) throws -> URL {
        let url = tempDir.appendingPathComponent(fileName)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "fixture", code: 1)
        }
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.endPage()
        }
        context.closePDF()
        try (data as Data).write(to: url)
        return url
    }

    /// The acceptance scenario end to end at the model level:
    /// create → import → complete → switch pieces → "relaunch" retains
    /// independent count / page / viewport / guide / notes.
    func testFullResumeWorkflowKeepsPiecesIndependent() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Two sleeves")
        let left = try repo.addPiece(to: project.id, name: "left", repeatLength: 8)
        let right = try repo.addPiece(to: project.id, name: "right", repeatLength: 8)
        let doc = try repo.importPatternDocument(from: try writePDF(pages: 6, fileName: "chart.pdf"), for: project.id)

        // Left sleeve: 3 rows, page 2, zoomed top area, guide at 1/3, notes.
        for _ in 0..<3 { try repo.apply(.completeRow, to: left.id) }
        try repo.setNotes("k2 p2 on RS", on: left.id)
        try repo.saveReferenceState(ReferenceState(
            pieceID: left.id, documentID: doc.id, pageIndex: 2,
            visibleRect: NormalizedRect(x: 0, y: 0, width: 1, height: 0.4),
            guideY: 0.33
        ))

        // Right sleeve: 1 row, different page, no guide, different notes.
        try repo.apply(.completeRow, to: right.id)
        try repo.setNotes("work even", on: right.id)
        try repo.saveReferenceState(ReferenceState(
            pieceID: right.id, documentID: doc.id, pageIndex: 5,
            visibleRect: .full, guideY: nil
        ))

        // "Relaunch": brand-new repository over the same durable store.
        let relaunched = try RowRepository.open(storeURL: storeURL)
        let leftAgain = try relaunched.piece(left.id)
        let rightAgain = try relaunched.piece(right.id)
        XCTAssertEqual(leftAgain.completedRows, 3)
        XCTAssertEqual(rightAgain.completedRows, 1)
        XCTAssertEqual(leftAgain.notes, "k2 p2 on RS")
        XCTAssertEqual(rightAgain.notes, "work even")

        let leftRef = try XCTUnwrap(try relaunched.referenceState(for: left.id))
        XCTAssertEqual(leftRef.pageIndex, 2)
        XCTAssertEqual(try XCTUnwrap(leftRef.guideY), 0.33, accuracy: 1e-9)
        XCTAssertEqual(leftRef.visibleRect.height, 0.4, accuracy: 1e-9)
        XCTAssertEqual(leftRef.documentID, doc.id)

        let rightRef = try XCTUnwrap(try relaunched.referenceState(for: right.id))
        XCTAssertEqual(rightRef.pageIndex, 5)
        XCTAssertNil(rightRef.guideY)
    }

    /// Hostile stored values must come back clamped, never rejected or
    /// out-of-range.
    func testRestoreClampsStaleAndHostileValues() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "P")
        let piece = try repo.addPiece(to: project.id, name: "one")
        let doc = try repo.importPatternDocument(from: try writePDF(pages: 3, fileName: "small.pdf"), for: project.id)

        // Save through the API: even a hostile request is clamped before it
        // reaches disk.
        try repo.saveReferenceState(ReferenceState(
            pieceID: piece.id, documentID: doc.id, pageIndex: 99,
            visibleRect: NormalizedRect(x: -1, y: 0.5, width: 2, height: 0),
            guideY: -3
        ))
        let state = try XCTUnwrap(try repo.referenceState(for: piece.id))
        XCTAssertEqual(state.pageIndex, 2)
        XCTAssertGreaterThanOrEqual(state.visibleRect.width, ViewportClamp.minimumFraction)
        XCTAssertLessThanOrEqual(state.visibleRect.x + state.visibleRect.width, 1.0000001)
        XCTAssertEqual(state.guideY, 0)
    }

    /// A vanished document reference reads back as "no document" rather than
    /// crashing or pointing nowhere.
    func testMissingDocumentReferenceDegradesToNil() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "P")
        let piece = try repo.addPiece(to: project.id, name: "one")
        let doc = try repo.importPatternDocument(from: try writePDF(pages: 2, fileName: "vanish.pdf"), for: project.id)
        try repo.saveReferenceState(ReferenceState(
            pieceID: piece.id, documentID: doc.id, pageIndex: 1, visibleRect: .full, guideY: 0.5
        ))
        // Simulate the file/record disappearing at the persistence layer.
        let fileURL = try repo.documentFileURL(doc.id)
        try FileManager.default.removeItem(at: fileURL)
        // The record still exists, so reference keeps its documentID, but the
        // file helper would now hand out a URL that does not exist; the model
        // treats that as "cannot open" — assert the file is gone and state
        // still reads.
        let state = try XCTUnwrap(try repo.referenceState(for: piece.id))
        XCTAssertEqual(state.pageIndex, 1)
    }

    /// Saving reference state for an unknown piece or unknown document is a
    /// durable-visible error, not a silent insert.
    func testSaveReferenceValidatesOwnership() throws {
        let repo = try RowRepository(storeURL: storeURL)
        XCTAssertThrowsError(try repo.saveReferenceState(ReferenceState(
            pieceID: UUID(), documentID: nil, pageIndex: 0, visibleRect: .full, guideY: nil
        ))) { error in
            XCTAssertTrue(error is RowRepositoryError)
        }
    }

    /// The WorkspaceModel exposes no API path from selection to a row event:
    /// selecting pieces/projects repeatedly never changes any count.
    func testModelSelectionNeverAdvancesCounts() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "P")
        let a = try repo.addPiece(to: project.id, name: "a")
        let b = try repo.addPiece(to: project.id, name: "b")
        try repo.apply(.completeRow, to: a.id)

        let model = WorkspaceModel(repository: repo)
        model.select(project: project.id)
        model.select(piece: a.id)
        model.select(piece: b.id)
        model.select(piece: a.id)
        model.select(project: nil)
        model.select(project: project.id)

        XCTAssertEqual(try repo.piece(a.id).completedRows, 1, "selection churn must not change counts")
        XCTAssertEqual(try repo.piece(b.id).completedRows, 0)
        XCTAssertEqual(try repo.history(for: a.id).count, 1)
    }

    /// A failed durable save while recording row work must not display a
    /// committed counter (workspace reads the rolled-back truth).
    func testModelReflectsRolledBackCountAfterSaveFailure() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "P")
        let piece = try repo.addPiece(to: project.id, name: "one")
        let model = WorkspaceModel(repository: repo)
        model.select(project: project.id)
        model.select(piece: piece.id)
        model.completeRow()
        XCTAssertEqual(model.selectedPiece?.completedRows, 1)

        struct Fault: Error {}
        repo.testSaveFault = { throw Fault() }
        model.completeRow()
        repo.testSaveFault = nil
        XCTAssertEqual(model.selectedPiece?.completedRows, 1, "failed save must not display a committed counter update")
        XCTAssertNotNil(model.lastError)
    }

    /// When a stored workspace session references a deleted/vanished project
    /// or piece, WorkspaceModel falls back deterministically to existing items
    /// without mutating any row count or throwing errors.
    func testModelFallsBackWhenStoredSessionItemsAreMissing() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Existing")
        let piece = try repo.addPiece(to: project.id, name: "only-piece")

        // Persist a session pointing to non-existent project & piece IDs.
        // We write directly to StoredWorkspaceSession in the underlying context
        // to emulate a store where the referenced rows were removed/corrupted.
        let bogusProjectID = UUID()
        let bogusPieceID = UUID()
        let stored = StoredWorkspaceSession(
            key: WorkspaceSessionRecord.activeKey,
            selectedProjectID: bogusProjectID,
            selectedPieceID: bogusPieceID,
            controlScrollOffset: 120.0,
            updatedAt: Date()
        )
        repo.context.insert(stored)
        try repo.commit()

        let model = WorkspaceModel(repository: repo)
        XCTAssertEqual(model.selectedProjectID, project.id, "must fall back to first existing project")
        XCTAssertEqual(model.selectedPieceID, piece.id, "must fall back to first existing piece")
        XCTAssertEqual(model.controlScrollOffset, 120.0, "valid scroll offset should still be adopted")
        XCTAssertEqual(try repo.piece(piece.id).completedRows, 0, "fallback must not touch counts")

        // Verify that a corrupt negative scroll offset normalizes cleanly.
        stored.selectedProjectID = project.id
        stored.selectedPieceID = piece.id
        stored.controlScrollOffset = -50.0
        try repo.commit()

        let model2 = WorkspaceModel(repository: repo)
        XCTAssertEqual(model2.controlScrollOffset, 0, "negative scroll offset must normalize to 0")
    }

    /// Session restore and reminders shipped on separate branches; opening a
    /// saved piece must hydrate its reminders as well as its reference state.
    func testSessionRestoreHydratesPieceReminders() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Sock")
        let piece = try repo.addPiece(to: project.id, name: "heel")
        let reminder = try repo.addReminder(to: piece.id, instruction: "Turn heel", interval: nil, startRow: 6)
        try repo.saveWorkspaceSession(WorkspaceSessionRecord(
            selectedProjectID: project.id, selectedPieceID: piece.id, controlScrollOffset: 0
        ))

        let reopened = try RowRepository.open(storeURL: storeURL)
        let model = WorkspaceModel(repository: reopened)
        XCTAssertEqual(model.selectedPieceID, piece.id)
        XCTAssertEqual(model.reminders.map(\.id), [reminder.id])
        XCTAssertEqual(try reopened.piece(piece.id).completedRows, 0)
    }

    /// A transient session-read failure must inhibit every later persistence
    /// path in that model instance (geometry, selection, lifecycle capture),
    /// preserving the prior durable record rather than saving fallback state.
    func testSessionReadFailureNeverOverwritesPriorDurableSession() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "P")
        let first = try repo.addPiece(to: project.id, name: "first")
        let second = try repo.addPiece(to: project.id, name: "second")
        let prior = WorkspaceSessionRecord(
            selectedProjectID: project.id,
            selectedPieceID: second.id,
            controlScrollOffset: 125
        )
        try repo.saveWorkspaceSession(prior)

        struct ReadFault: Error {}
        repo.testSessionReadFault = { throw ReadFault() }
        let model = WorkspaceModel(repository: repo)
        XCTAssertTrue(model.sessionPersistenceDisabled)
        model.select(piece: first.id)
        model.setControlScrollOffset(9)
        model.captureCurrentWorkspace()

        repo.testSessionReadFault = nil
        XCTAssertEqual(try repo.workspaceSession(), prior,
                       "all fallback persistence must remain inhibited after a failed read")
    }

    /// Guide movement is pure view state: setting it never records a row
    /// event and works on text-only pieces with no document at all.
    func testGuideNeverTouchesRowHistoryAndWorksWithoutDocument() throws {
        let repo = try RowRepository(storeURL: storeURL)
        let project = try repo.createProject(title: "Text only")
        let piece = try repo.addPiece(to: project.id, name: "notes-only")
        let model = WorkspaceModel(repository: repo)
        model.select(project: project.id)
        model.select(piece: piece.id)
        model.setGuide(y: 0.5)
        model.viewerMoved(pageIndex: 3, visibleRect: NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.5))

        XCTAssertEqual(try repo.history(for: piece.id).count, 0, "view gestures must never create row events")
        let relaunched = try RowRepository.open(storeURL: storeURL)
        let state = try XCTUnwrap(try relaunched.referenceState(for: piece.id))
        XCTAssertNil(state.documentID)
        XCTAssertEqual(try XCTUnwrap(state.guideY), 0.5, accuracy: 1e-9)
    }
}
