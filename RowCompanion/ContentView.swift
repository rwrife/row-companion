import SwiftUI
import UniformTypeIdentifiers

/// Root workspace screen (issue #3): project/piece selection, bounded PDF
/// import via the system Files picker, the `WorkspaceLayout` seam, and error
/// surface. Durable state lives entirely in `WorkspaceModel` above the view
/// tree, so view identity churn (sheet presentation, size-class changes)
/// never touches counts or viewport.
struct ContentView: View {
    @Environment(WorkspaceModel.self) private var model
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
