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
        // Arrangement reads exactly two environment facts through the pure
        // `WorkspaceArrangement` rules — nothing here touches durable state,
        // so any reflow (rotation, size-class change, Dynamic Type growth,
        // pane reorder) can never emit a row event or reset counters.
        // The launch-argument override is a simulator-journey seam (same
        // pattern as `-rc-ui-tests-reset`) so the two-pane branch and pane
        // reorder can be exercised on the compact iPhone UDID CI boots;
        // normal app launches never pass it.
        let forcedTwoPane = CommandLine.arguments.contains("-rc-force-two-pane")
        let useTwoPane = forcedTwoPane || WorkspaceArrangement.useTwoPane(
            regularWidth: horizontalSizeClass == .regular,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
        )
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
///
/// Pane order is user-reversible. The reorder is *arrangement only*: both
/// panes are the same stateless keyed views and all durable state lives in
/// `WorkspaceModel` above this branch, so flipping order cannot reset the
/// count, notes, page, guide, or viewport, and cannot emit a row event.
private struct RegularWorkspace: View {
    @State private var paneOrder: WorkspacePaneOrder = .referenceFirst

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Group {
                    switch paneOrder {
                    case .referenceFirst:
                        ReferencePane()
                        Divider()
                        ControlPane()
                    case .controlsFirst:
                        ControlPane()
                        Divider()
                        ReferencePane()
                    }
                }
            }
            Button {
                paneOrder = WorkspaceArrangement.flipped(paneOrder)
            } label: {
                Label("Switch panes", systemImage: "rectangle.2.swap")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("control.paneOrder")
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
    @State private var showReminderComposer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let piece = model.selectedPiece {
                    ProgressReadout(piece: piece)
                    counterButtons
                    if let notice = model.crossingNotice, !notice.isEmpty {
                        Text(notice.summaryText)
                            .font(.callout)
                            .accessibilityIdentifier("reminder.crossingNotice")
                    }
                    if !model.remindersDueNextRow.isEmpty {
                        Text("Due next row: " + model.remindersDueNextRow.map(\.instruction).joined(separator: " · "))
                            .font(.headline)
                            .accessibilityIdentifier("reminder.dueBanner")
                    }
                    repeatPicker(piece: piece)
                    if model.referenceDocumentURL != nil {
                        guideSlider
                    }
                    notesEditor(piece: piece)
                    remindersSection(piece: piece)
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

    /// Manual reading guide control: a slider (VoiceOver-adjustable, keyboard
    /// and Switch Control operable — no mandatory drag gesture on the PDF
    /// itself) plus an explicit off switch. It writes only view state
    /// through `WorkspaceModel.setGuide`, never a row action.
    private var guideSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading guide")
                .font(.headline)
            Slider(
                value: Binding(
                    get: { model.reference?.guideY ?? 0.5 },
                    set: { model.setGuide(y: $0) }
                ),
                in: 0...1
            ) {
                Text("Guide position")
            } minimumValueLabel: {
                Image(systemName: "line.horizontal.3").accessibilityHidden(true)
            } maximumValueLabel: {
                Image(systemName: "line.horizontal.3").accessibilityHidden(true)
            }
            .accessibilityIdentifier("control.guideSlider")
            Button("Guide off") { model.setGuide(y: nil) }
                .frame(minHeight: 44)
                .accessibilityIdentifier("control.guideOff")
        }
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
                Button("Apply correction", role: .destructive) {
                    // This explicitly labelled alert action is the user's
                    // confirmation. A Toggle inside an iOS 26 alert dismisses
                    // the alert on tap, leaving Apply unreachable.
                    model.correctCount(to: Int(correctionText) ?? -1, confirmed: true)
                }
                .accessibilityIdentifier("control.applyCorrection")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Replace the completed-row count? This records a correction in the piece history; Cancel keeps the current count.")
            }
        }
    }

    /// Piece-scoped shaping reminders (issue #15): durable instructions the
    /// workspace shows when due. No notification permissions are requested —
    /// due state is derived live from the durable row count and recomputed
    /// after complete/undo/correction/repeat edits and relaunch.
    private func remindersSection(piece: PieceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shaping reminders")
                .font(.headline)
            if model.reminders.isEmpty {
                Text("No reminders yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reminder.empty")
            } else {
                ForEach(model.reminders) { reminder in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.instruction)
                            Text(ReminderRules.ruleDescription(for: reminder))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // The milestone-reached state is persistent list
                            // copy, deliberately distinct from the transient
                            // next-row due banner above the counters.
                            if model.remindersMilestoneReached.contains(reminder) {
                                Text("Milestone reached")
                                    .font(.caption)
                                    .accessibilityIdentifier("reminder.reached")
                            }
                        }
                        Spacer()
                        Button("Remove") { model.removeReminder(id: reminder.id) }
                            .accessibilityIdentifier("button.reminder.remove")
                    }
                    // NOTE: no accessibilityIdentifier on this row container —
                    // an identifier on a multi-element row overwrites the child
                    // identifiers in the AX tree (the badge/button queries would
                    // then never resolve). Identify children individually.
                }
            }
            Button("Add reminder…") { showReminderComposer = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("button.addReminder")
        }
        .sheet(isPresented: $showReminderComposer) {
            ReminderComposer(isPresented: $showReminderComposer)
        }
    }
}

/// Sheet that authors one reminder. Start/end rows and the interval are
/// free numeric fields validated by the pure `ReminderRules` on save —
/// invalid values never reach disk and the sheet stays open with the
/// server-side problem text.
private struct ReminderComposer: View {
    @Environment(WorkspaceModel.self) private var model
    @Binding var isPresented: Bool
    @State private var instruction = ""
    @State private var cadence: Cadence = .once
    @State private var startText = "1"
    @State private var intervalText = "6"
    @State private var endText = ""
    @State private var validationMessage: String?

    enum Cadence: Hashable {
        case once
        case everyRows
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Instruction", text: $instruction)
                    .accessibilityIdentifier("field.reminder.instruction")
                Picker("Cadence", selection: $cadence) {
                    Text("Once at row").tag(Cadence.once)
                    Text("Every N rows").tag(Cadence.everyRows)
                }
                .accessibilityIdentifier("control.reminder.cadence")
                TextField("Starting row", text: $startText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("field.reminder.startRow")
                if cadence == .everyRows {
                    TextField("Interval (rows)", text: $intervalText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("field.reminder.interval")
                }
                TextField("Last row (optional)", text: $endText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("field.reminder.endRow")
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("reminder.validation")
                }
            }
            .navigationTitle("New reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("button.reminder.save")
                }
            }
        }
    }

    private func save() {
        let interval = cadence == .everyRows ? Int(intervalText.trimmingCharacters(in: .whitespaces)) : nil
        let endRow = Int(endText.trimmingCharacters(in: .whitespaces))
        // Clear any unrelated prior error so the outcome of *this* save is
        // the only thing inspected below.
        model.lastError = nil
        model.addReminder(
            instruction: instruction,
            interval: interval,
            startRow: Int(startText.trimmingCharacters(in: .whitespaces)) ?? 0,
            endRow: endRow
        )
        // Invalid reminders never reach disk; the sheet keeps the problem
        // text so the maker can fix the field in place.
        if let error = model.lastError {
            validationMessage = error.userMessage
        } else {
            isPresented = false
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
