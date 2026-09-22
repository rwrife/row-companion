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
    @State private var newProjectTitle = ""
    @State private var newPieceName = ""
    @State private var newPieceRepeat = ""

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
}
