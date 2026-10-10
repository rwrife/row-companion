import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Root workspace screen (issue #3): project/piece selection, bounded PDF
/// import via the system Files picker, the `WorkspaceLayout` seam, and error
/// surface. Durable state lives entirely in `WorkspaceModel` above the view
/// tree, so view identity churn (sheet presentation, size-class changes)
/// never touches counts or viewport.
struct ContentView: View {
    @Environment(WorkspaceModel.self) private var model
    @AppStorage("focus.haptics") private var focusHaptics = false
    @AppStorage("focus.keepAwake") private var focusKeepAwake = false
    @State private var showFocus = false
    @State private var showLibrary = false
    @State private var showNewProject = false
    @State private var showNewPiece = false
    @State private var showImporter = false
    @State private var showExportSheet = false
    @State private var showFolderPicker = false
    @State private var showDeleteConfirm = false
    @State private var exportAcknowledged = false
    @State private var fullBackupAcknowledged = false
    @State private var deleteAcknowledged = false
    @State private var newProjectTitle = ""
    @State private var newPieceName = ""
    @State private var newPieceRepeat = ""
    /// Which folder action the shared folder picker should run.
    @State private var pendingFolderAction: FolderAction?

    enum FolderAction {
        case exportProgress
        case fullBackup
        case restore
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WorkspaceLayout()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError?.userMessage ?? "")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            // Cancellation produces no callback path here; a .success with an
            // empty/invalid URL is ignored, and any import failure surfaces
            // through `lastError` with no partial record (PDFImport stages
            // atomically).
            if case .success(let urls) = result, let url = urls.first {
                model.importPDF(from: url)
            }
        }
        .fullScreenCover(isPresented: $showFocus) {
            FocusCountingView(
                hapticsEnabled: $focusHaptics,
                keepAwakeEnabled: $focusKeepAwake
            )
        }
        .sheet(isPresented: $showLibrary) { ProjectLibraryView() }
        .sheet(isPresented: $showNewProject) { newProjectSheet }
        .sheet(isPresented: $showNewPiece) { newPieceSheet }
        .sheet(isPresented: $showExportSheet) { exportSheet }
        .sheet(
            isPresented: Binding(
                get: { model.restorePreview != nil },
                set: { if !$0 { model.cancelRestore() } }
            )
        ) { restoreSheet }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            defer { pendingFolderAction = nil }
            guard case .success(let urls) = result, let url = urls.first,
                  let action = pendingFolderAction else { return }
            switch action {
            case .exportProgress: model.exportProgress(to: url)
            case .fullBackup: model.exportFullBackup(to: url)
            case .restore: model.prepareRestore(from: url)
            }
        }
        .confirmationDialog(
            "Delete this project?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                model.deleteSelectedProject(confirmed: deleteAcknowledged)
                deleteAcknowledged = false
                showDeleteConfirm = false
            }
            .disabled(!deleteAcknowledged)
            .accessibilityIdentifier("button.confirmDelete")
            Button("Cancel", role: .cancel) {
                model.deleteSelectedProject(confirmed: false)
                deleteAcknowledged = false
            }
        } message: {
            Text("The project, its pieces, history, and the pattern copies the app made for it are removed. \(model.deletionScopeNote)")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Row Companion")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("workspace.title")
                Spacer()
                Menu {
                    Button("Focused counting", action: { showFocus = true })
                        .accessibilityIdentifier("focus.enter")
                        .disabled(model.selectedPieceID == nil)
                    Button("Project Library", action: { showLibrary = true })
                        .accessibilityIdentifier("menu.library")
                    Button("New project", action: { showNewProject = true })
                        .accessibilityIdentifier("menu.newProject")
                    Button("New piece", action: { showNewPiece = true })
                        .accessibilityIdentifier("menu.newPiece")
                    Button("Import pattern PDF", action: { showImporter = true })
                        .accessibilityIdentifier("menu.importPDF")
                        .disabled(model.selectedProjectID == nil || model.isImporting)
                    Divider()
                    Button("Export / Back Up…", action: { showExportSheet = true })
                        .accessibilityIdentifier("menu.export")
                        .disabled(model.selectedProjectID == nil || model.isBackupBusy)
                    Button("Restore Backup…", action: { pendingFolderAction = .restore; showFolderPicker = true })
                        .accessibilityIdentifier("menu.restore")
                        .disabled(model.isBackupBusy)
                    Button("Delete Project…", role: .destructive, action: { showDeleteConfirm = true })
                        .accessibilityIdentifier("menu.delete")
                        .disabled(model.selectedProjectID == nil)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("menu.add")
            }

            if !model.projects.isEmpty {
                Picker("Project", selection: projectSelection) {
                    ForEach(model.projects) { project in
                        Text(project.title).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("control.project")

                Picker("Piece", selection: pieceSelection) {
                    ForEach(model.pieces) { piece in
                        Text(piece.name).tag(Optional(piece.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("control.piece")
            }

            Text(model.statusMessage)
                .font(.subheadline)
                .accessibilityIdentifier("workspace.status")
        }
        .padding(.horizontal)
    }

    private var projectSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedProjectID },
            set: { model.select(project: $0) }
        )
    }

    private var pieceSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedPieceID },
            set: { model.select(piece: $0) }
        )
    }

    private var newProjectSheet: some View {
        NavigationStack {
            Form {
                TextField("Project title (e.g. Scarf)", text: $newProjectTitle)
                    .accessibilityIdentifier("field.projectTitle")
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        model.createProject(title: newProjectTitle)
                        newProjectTitle = ""
                        showNewProject = false
                    }
                    .disabled(newProjectTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("button.createProject")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewProject = false }
                }
            }
        }
    }

    private var newPieceSheet: some View {
        NavigationStack {
            Form {
                TextField("Piece name (e.g. Front)", text: $newPieceName)
                    .accessibilityIdentifier("field.pieceName")
                TextField("Repeat length (optional)", text: $newPieceRepeat)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("field.pieceRepeat")
            }
            .navigationTitle("New Piece")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let length = Int(newPieceRepeat)
                        model.addPiece(name: newPieceName, repeatLength: length)
                        newPieceName = ""
                        newPieceRepeat = ""
                        showNewPiece = false
                    }
                    .disabled(newPieceName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("button.addPiece")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewPiece = false }
                }
            }
        }
    }

    // MARK: - Backup sheets (issue #5)

    /// Privacy/copyright acknowledgements gate both export modes. The
    /// default progress export warns about leaving app storage; the full
    /// backup additionally warns about licensed originals and requires its
    /// own checkbox before its button enables.
    private var exportSheet: some View {
        NavigationStack {
            // Plain ScrollView/VStack (not a lazy List) so both toggles and
            // both buttons are laid out immediately on compact phones — the
            // privacy gates must never be reachable only by scrolling.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Progress export (default)").font(.headline)
                        ForEach(model.exportWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.footnote)
                        }
                        Toggle(isOn: $exportAcknowledged) {
                            Text("I understand where this file goes is my responsibility")
                        }
                        .accessibilityIdentifier("toggle.acknowledgeExport")
                        Button("Choose Folder…") {
                            pendingFolderAction = .exportProgress
                            showFolderPicker = true
                            showExportSheet = false
                        }
                        .disabled(!exportAcknowledged || model.isBackupBusy)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("button.exportProgress")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full backup (includes your pattern PDFs)").font(.headline)
                        ForEach(model.fullBackupWarnings, id: \.self) { warning in
                            Text(warning)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        Toggle(isOn: $fullBackupAcknowledged) {
                            Text("I have the right to keep and move these pattern copies")
                        }
                        .accessibilityIdentifier("toggle.acknowledgeOriginals")
                        Button("Choose Folder…") {
                            pendingFolderAction = .fullBackup
                            showFolderPicker = true
                            showExportSheet = false
                        }
                        .disabled(!fullBackupAcknowledged || model.isBackupBusy)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("button.exportFullBackup")
                    }
                }
                .padding()
            }
            .navigationTitle("Export / Back Up")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showExportSheet = false }
                }
            }
        }
    }

    /// Confirmation sheet shown *after* a staged backup has fully validated.
    /// Restoring always creates a new project — this sheet is the point
    /// where the user sees exactly what will be created.
    private var restoreSheet: some View {
        NavigationStack {
            List {
                if let preview = model.restorePreview {
                    Section("Restore as a NEW project") {
                        LabeledContent("Project", value: preview.projectTitle)
                        LabeledContent("Pieces", value: preview.pieceNames.joined(separator: ", "))
                        LabeledContent("Patterns", value: "\(preview.documentCount)")
                        Text("Existing projects are never overwritten or merged; everything below gets fresh IDs.")
                            .font(.footnote)
                    }
                    Section {
                        Button("Restore", role: .none) {
                            model.confirmRestore()
                        }
                        .disabled(model.isBackupBusy)
                        .accessibilityIdentifier("button.confirmRestore")
                    }
                }
            }
            .navigationTitle("Confirm Restore")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelRestore() }
                        .accessibilityIdentifier("button.cancelRestore")
                }
            }
        }
    }
}

/// A modal display of the same selected piece. Closing the cover reuses the
/// existing workspace model and its untouched PDF/notes/guide state.
private struct FocusCountingView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var hapticsEnabled: Bool
    @Binding var keepAwakeEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var readoutSize = 54

    // ponytail: UIApplication's idle timer is process-wide. Gate it on this
    // foreground cover and restore it on exit; use a scene-specific assertion
    // if the app ever gains multiple active window scenes.
    private var shouldKeepAwake: Bool { keepAwakeEnabled && scenePhase == .active }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Focused counting").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Back to pattern") { dismiss() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("focus.exit")
            }
            if let piece = model.selectedPiece {
                Text(piece.name).font(.title2).accessibilityIdentifier("focus.piece")
                Spacer(minLength: 8)
                Text(RowLabels.completedRows(piece.completedRows))
                    .font(.system(size: readoutSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .accessibilityIdentifier("focus.completed")
                if let next = piece.nextRepeatRow {
                    Text(RowLabels.nextRepeatRow(next))
                        .font(.title.bold())
                        .accessibilityIdentifier("focus.next")
                }
                Text(model.statusMessage)
                    .font(.callout)
                    .accessibilityIdentifier("focus.status")
                Spacer(minLength: 8)
                Button("Complete row") {
                    if model.completeRow() && hapticsEnabled && !UIAccessibility.isReduceMotionEnabled {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 60)
                .accessibilityIdentifier("focus.complete")
                Button("Undo") {
                    if model.undoRow() && hapticsEnabled && !UIAccessibility.isReduceMotionEnabled {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 60)
                .accessibilityIdentifier("focus.undo")
                Toggle("Haptic confirmation after saved row actions", isOn: $hapticsEnabled)
                    .accessibilityIdentifier("focus.haptics")
                Toggle("Keep screen awake while focused", isOn: $keepAwakeEnabled)
                    .accessibilityIdentifier("focus.keepAwake")
            } else {
                Text("Choose a piece before counting.")
            }
        }
        .padding()
        // ponytail: the idle timer is process-wide and nothing else in this
        // app holds it; if that ever changes, take/restore the previous value.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake }
        .onChange(of: shouldKeepAwake) { _, active in
            UIApplication.shared.isIdleTimerDisabled = active
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .alert("Count not saved", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) { Button("OK") { model.lastError = nil } }
        message: { Text(model.lastError?.userMessage ?? "Nothing was counted.") }
    }
}

/// Library navigation is independent of counter actions and retains the workspace contracts.
struct ProjectLibraryView: View {
    @Environment(WorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [LibrarySummary] = []
    @State private var search = ""
    @State private var status: ProjectStatus = .active
    @State private var sort = "Last worked"
    private struct EditRequest: Identifiable {
        let summary: LibrarySummary
        let duplicate: Bool
        var id: UUID { summary.id }
    }
    @State private var editing: EditRequest?
    @State private var deleting: LibrarySummary?
    @State private var error: String?

    private var visible: [LibrarySummary] {
        summaries.filter {
            $0.status == status && (search.isEmpty || $0.project.title.localizedStandardContains(search))
        }.sorted {
            switch sort {
            case "Title":
                let order = $0.project.title.localizedStandardCompare($1.project.title)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            case "Created": return $0.project.createdAt > $1.project.createdAt
            default:
                let lhs = $0.lastWorkedAt ?? $0.project.createdAt
                let rhs = $1.lastWorkedAt ?? $1.project.createdAt
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Status", selection: $status) {
                    ForEach(ProjectStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("library.status")
                Picker("Sort projects", selection: $sort) {
                    ForEach(["Last worked", "Title", "Created"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("library.sort")
                if visible.isEmpty {
                    Text(search.isEmpty ? "No \(status.rawValue) projects." : "No matching projects.")
                }
                ForEach(visible) { summary in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            if model.selectedProjectID != summary.id { model.select(project: summary.id) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.project.title).font(.headline)
                                Text("\(summary.status.label) · \(summary.pieceCount) pieces · \(summary.completedRows) completed rows")
                                    .font(.subheadline)
                                if let date = summary.lastWorkedAt {
                                    Text("Last worked \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                                } else { Text("Not worked yet").font(.caption) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.open." + summary.project.title)
                        Menu("Project actions") {
                            Button("Rename") { edit(summary, duplicate: false) }
                            Button("Duplicate setup") { edit(summary, duplicate: true) }
                            ForEach(ProjectStatus.allCases, id: \.self) { newStatus in
                                Button("Mark \(newStatus.label)") {
                                    perform { try model.repository.setProjectStatus(summary.id, status: newStatus) }
                                }
                            }
                            Button("Delete…", role: .destructive) { deleting = summary }
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel("Actions for " + summary.project.title)
                        .accessibilityIdentifier("library.actions." + summary.project.title)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search project titles")
            .navigationTitle("Project Library")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { refresh() }
            .sheet(item: $editing) { request in
                LibraryEditView(summary: request.summary, duplicating: request.duplicate) { title, copyProgress in
                    if request.duplicate {
                        if copyProgress && model.selectedProjectID == request.summary.id {
                            try model.captureReferenceForDuplication()
                        }
                        _ = try model.repository.duplicateProject(request.summary.id, title: title, copyProgress: copyProgress)
                        status = .active
                    } else { try model.repository.renameProject(request.summary.id, title: title) }
                    refresh()
                }
            }
            .confirmationDialog("Delete project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Project", role: .destructive) {
                    guard let target = deleting else { return }
                    perform {
                        try model.repository.deleteProject(target.id, confirmed: true)
                        model.projectWasDeleted(target.id)
                    }
                    deleting = nil
                }
                Button("Keep Project") { deleting = nil }
                    .accessibilityIdentifier("library.keepProject")
            } message: {
                Text("This removes the project, pieces, history, and app-owned pattern copies. User exports and OS backups remain outside the app's control.")
            }
            .alert("Library change failed", isPresented: errorPresented) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    }
    private func edit(_ summary: LibrarySummary, duplicate: Bool) {
        editing = EditRequest(summary: summary, duplicate: duplicate)
    }
    private func refresh() {
        do { summaries = try model.repository.librarySummaries(); model.reload() }
        catch { self.error = "The library could not be read. Please try again." }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); refresh() }
        catch { self.error = "The project change could not be saved. Please try again." }
    }
}

private struct LibraryEditView: View {
    @Environment(\.dismiss) private var dismiss
    let duplicating: Bool
    let save: (String, Bool) throws -> Void
    @State private var title: String
    @State private var copyProgress = false
    @State private var failed = false

    init(summary: LibrarySummary, duplicating: Bool, save: @escaping (String, Bool) throws -> Void) {
        self.duplicating = duplicating
        self.save = save
        _title = State(initialValue: summary.project.title + (duplicating ? " Copy" : ""))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project title", text: $title).accessibilityIdentifier("library.title")
                if duplicating {
                    Toggle("Copy progress and history", isOn: $copyProgress)
                        .accessibilityIdentifier("library.copyProgress")
                    Text("By default, counts start at zero and history, checkpoints, and reading position start fresh. Piece names, repeat settings, notes, reminders, and independent pattern copies are included. Copy progress also preserves counts, full undo history, checkpoints, and reading position.")
                }
            }
            .navigationTitle(duplicating ? "Duplicate Setup" : "Rename Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try save(title, copyProgress); dismiss() }
                        catch { failed = true }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("library.save")
                }
            }
            .alert("Library change failed", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: { Text("The project change could not be saved. Please try again.") }
        }
    }
}
