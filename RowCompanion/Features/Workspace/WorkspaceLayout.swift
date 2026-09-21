import SwiftUI
import PDFKit

/// The layout seam from PLAN.md ("Adaptive layout seam"): arrangement is
/// chosen *only* from available width and accessibility traits, and state
/// lives above the branches in `WorkspaceModel`. Both branches render the
/// same piece/document keyed content, so switching arrangement can never
/// mutate counts, notes, page, guide, or viewport.
struct WorkspaceLayout: View {
    @Environment(WorkspaceModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        #if os(iOS)
        // Two panes need regular width AND readable type; reflow to stacked
        // when Dynamic Type would make a side pane unusable.
        let useTwoPane = horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
        if useTwoPane {
            RegularWorkspace()
        } else {
            CompactWorkspace()
        }
        #else
        CompactWorkspace()
        #endif
    }
}

/// Compact phone: readable reference above, reachable controls below.
private struct CompactWorkspace: View {
    var body: some View {
        VStack(spacing: 12) {
            ReferencePane()
            ControlPane()
        }
        .padding(.horizontal)
    }
}

/// Regular width: reference beside the control/notes pane.
private struct RegularWorkspace: View {
    var body: some View {
        HStack(spacing: 16) {
            ReferencePane()
            Divider()
            ControlPane()
        }
        .padding(.horizontal)
    }
}

// MARK: - Reference pane (PDF viewer + manual guide)

private struct ReferencePane: View {
    @Environment(WorkspaceModel.self) private var model

    var body: some View {
        Group {
            if let url = model.referenceDocumentURL {
                RowPDFView(
                    documentURL: url,
                    reference: model.reference ?? ReferenceState(
                        pieceID: model.selectedPieceID ?? UUID(),
                        documentID: nil, pageIndex: 0, visibleRect: .full, guideY: nil
                    ),
                    onMoved: { page, rect in
                        model.viewerMoved(pageIndex: page, visibleRect: rect)
                    }
                )
                .accessibilityIdentifier("workspace.viewer")
                .overlay(alignment: .leading) {
                    if let guideY = model.reference?.guideY {
                        GuideReader(guideY: guideY)
                    }
                }
            } else {
                // Text-only projects are first-class: no PDF, just notes.
                ContentUnavailablePlaceholder()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text("No pattern attached")
                .font(.headline)
            Text("Import a PDF you own, or keep this piece with text notes only.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("workspace.noDocument")
    }
}

/// The manual reading guide is pure overlay art: it has no closure into the
/// row layer, so it can never advance a row (acceptance criterion 4).
private struct GuideReader: View {
    let guideY: Double
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.orange)
                .frame(height: 2)
                .offset(y: geo.size.height * guideY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Control pane

private struct ControlPane: View {
    @Environment(WorkspaceModel.self) private var model
    @State private var showCorrection = false
    @State private var correctionText = ""
    @State private var confirmCorrection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let piece = model.selectedPiece {
                    ProgressReadout(piece: piece)
                    counterButtons
                    repeatPicker(piece: piece)
                    notesEditor(piece: piece)
                } else {
                    Text("Add a project and a piece to start counting.")
                        .font(.body)
                        .accessibilityIdentifier("workspace.emptyControls")
                }
            }
            .padding(.vertical)
        }
        .frame(maxWidth: .infinity)
    }

    private var counterButtons: some View {
        HStack(spacing: 16) {
            Button {
                model.completeRow()
            } label: {
                Text("Complete row")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("control.completeRow")

            Button {
                model.undoRow()
            } label: {
                Text("Undo")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("control.undo")
        }
        .controlSize(.large)
    }

    private func repeatPicker(piece: PieceRecord) -> some View {
        Picker("Repeat length", selection: Binding(
            get: { piece.repeatLength ?? 0 },
            set: { model.setRepeatLength($0 == 0 ? nil : $0) }
        )) {
            Text("None").tag(0)
            ForEach([4, 6, 8, 10, 12], id: \.self) { length in
                Text("\(length)").tag(length)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("control.repeatLength")
    }

    private func notesEditor(piece: PieceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
            TextEditor(text: Binding(
                get: { piece.notes },
                set: { model.setNotes($0) }
            ))
            .frame(minHeight: 80)
            .accessibilityIdentifier("control.notes")
            Button("Correct count…", action: {
                correctionText = String(piece.completedRows)
                showCorrection = true
            })
            .accessibilityIdentifier("control.correct")
            .alert("Correct count", isPresented: $showCorrection) {
                TextField("Rows completed", text: $correctionText)
                    .keyboardType(.numberPad)
                Toggle("Confirm change", isOn: $confirmCorrection)
                Button("Apply") {
                    model.correctCount(to: Int(correctionText) ?? -1, confirmed: confirmCorrection)
                    confirmCorrection = false
                }
                Button("Cancel", role: .cancel) { confirmCorrection = false }
            } message: {
                Text("Set the completed-row count explicitly. Confirm to apply.")
            }
        }
    }
}

/// Compact readout of one piece's progress. Completed rows and the next
/// repeat row are separate, explicitly labelled values with their own
/// accessibility identifiers (no merged container, so VoiceOver focus and
/// UI automation can address each value).
private struct ProgressReadout: View {
    let piece: PieceRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(piece.name)
                .font(.title2.bold())
                .accessibilityIdentifier("piece.name")
            Text(RowLabels.completedRows(piece.completedRows))
                .font(.title3)
                .accessibilityLabel(RowLabels.completedRows(piece.completedRows))
                .accessibilityIdentifier("row.completed")
            if let next = piece.nextRepeatRow, let repeats = piece.completedRepeats {
                Text("\(RowLabels.nextRepeatRow(next)) · \(RowLabels.completedRepeats(repeats))")
                    .font(.title3)
                    .accessibilityLabel("\(RowLabels.nextRepeatRow(next)), \(RowLabels.completedRepeats(repeats))")
                    .accessibilityIdentifier("row.next")
            }
        }
    }
}
