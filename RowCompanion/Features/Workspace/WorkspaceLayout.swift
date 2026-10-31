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
        let arguments = CommandLine.arguments
        let forcedTwoPane = arguments.contains("-rc-force-two-pane")
        // `-rc-force-regular-width` exercises the real arrangement rule on
        // the compact CI phone: unlike the older direct two-pane override it
        // still allows an accessibility Dynamic Type category to reflow the
        // workspace to stacked. Normal launches never pass either argument.
        let regularWidth = arguments.contains("-rc-force-regular-width")
            || horizontalSizeClass == .regular
        let useTwoPane = forcedTwoPane || WorkspaceArrangement.useTwoPane(
            regularWidth: regularWidth,
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            ReferencePane()
                // At AX sizes the empty/PDF reference's flexible height can
                // consume almost the whole phone, leaving a control viewport
                // shorter than the enlarged Complete/Undo buttons. Reserve
                // room for the independent scrollable controls while keeping
                // the reference visible and its document viewport intact.
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 220 : .infinity)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showCorrection = false
    @State private var correctionText = ""
    @State private var showReminderComposer = false
    @State private var showHistory = false
    @State private var showCheckpointComposer = false
    @State private var checkpointToRestore: ProgressCheckpointRecord?
    @State private var showCounterComposer = false
    @State private var counterToCorrect: NamedCounter?
    @State private var counterCorrectionText = ""
    @State private var showDetailsEditor = false

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
                    detailsSection()
                    countersSection()
                    if model.referenceDocumentURL != nil {
                        guideSlider
                    }
                    notesEditor(piece: piece)
                    checkpointsSection(piece: piece)
                    historySection(piece: piece)
                    remindersSection(piece: piece)
                } else {
                    Text("Add a project and a piece to start counting.")
                        .font(.body)
                        .accessibilityIdentifier("workspace.emptyControls")
                }
            }
            .padding(.vertical)
        }
        .accessibilityIdentifier("workspace.controlsScroll")
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // A side-by-side pair narrows each target to half the phone;
                // at AX5 its wrapped title makes a button ~279 pt tall while
                // the control viewport may be only ~192 pt. Full-width
                // stacked buttons keep both labels and targets reachable.
                VStack(spacing: 12) {
                    completeRowButton
                    undoRowButton
                }
            } else {
                HStack(spacing: 16) {
                    completeRowButton
                    undoRowButton
                }
            }
        }
        .controlSize(.large)
    }

    private var completeRowButton: some View {
        Button {
            model.completeRow()
        } label: {
            Text("Complete row")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("control.completeRow")
    }

    private var undoRowButton: some View {
        Button {
            model.undoRow()
        } label: {
            Text("Undo")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("control.undo")
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

    /// Structured project/piece details (issue #20). Read summary plus an
    /// editor sheet; stored numbers are canonical metric, the display-unit
    /// toggle only converts presentation.
    private func detailsSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project details")
                .font(.headline)
            Text(model.effectiveDetails.summaryText(isImperial: model.usesImperialDisplay))
                .font(.callout)
                .accessibilityIdentifier("details.summary")
            Button("Edit details…") { showDetailsEditor = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("button.editDetails")
        }
        .sheet(isPresented: $showDetailsEditor) {
            DetailsEditor(isPresented: $showDetailsEditor)
        }
    }

    private func countersSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extra counters")
                .font(.headline)
            if !model.linkedCounterNames.isEmpty {
                Text("Complete row and Undo also change: " + model.linkedCounterNames.joined(separator: ", "))
                    .font(.callout)
                    .accessibilityIdentifier("counter.linkedGroup")
            }
            ForEach(model.counters) { counter in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(counter.name): \(counter.value)\(counter.unit.isEmpty ? "" : " " + counter.unit)"
                        + (counter.nextRepeat.map { " · next repeat row \($0)" } ?? ""))
                        .accessibilityIdentifier("counter.value")
                    HStack {
                        Button("Add 1") { model.advanceCounter(counter.id) }
                            .accessibilityIdentifier("button.counter.advance")
                        Button("Undo") { model.undoCounter(counter.id) }
                            .accessibilityIdentifier("button.counter.undo")
                        Button("Correct…") {
                            counterToCorrect = counter
                            counterCorrectionText = String(counter.value)
                        }
                        .accessibilityIdentifier("button.counter.correct")
                        Button("Remove", role: .destructive) { model.removeCounter(counter.id) }
                            .accessibilityIdentifier("button.counter.remove")
                    }
                    Toggle("Advance with Complete row", isOn: Binding(
                        get: { counter.advancesWithRows },
                        set: { model.setCounterLink(counter.id, linked: $0) }
                    ))
                    .accessibilityIdentifier("toggle.counter.link")
                }
            }
            Button("Add counter…") { showCounterComposer = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("button.addCounter")
        }
        .sheet(isPresented: $showCounterComposer) {
            CounterComposer(isPresented: $showCounterComposer)
        }
        .alert("Correct counter", isPresented: Binding(
            get: { counterToCorrect != nil },
            set: { if !$0 { counterToCorrect = nil } }
        )) {
            TextField("Value", text: $counterCorrectionText).keyboardType(.numberPad)
            Button("Apply correction", role: .destructive) {
                if let counter = counterToCorrect {
                    model.correctCounter(counter.id, to: Int(counterCorrectionText) ?? -1, reset: false)
                }
                counterToCorrect = nil
            }
            .accessibilityIdentifier("button.counter.applyCorrection")
            Button("Reset to start", role: .destructive) {
                if let counter = counterToCorrect {
                    model.correctCounter(counter.id, to: counter.startingValue, reset: true)
                }
                counterToCorrect = nil
            }
            Button("Cancel", role: .cancel) { counterToCorrect = nil }
        } message: {
            Text("This changes only this extra counter and records the change in its own history. Completed rows stay as they are.")
        }
    }

    private func checkpointsSection(piece: PieceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Progress checkpoints")
                .font(.headline)
            ForEach(model.checkpoints) { checkpoint in
                HStack(alignment: .firstTextBaseline) {
                    Text(CheckpointRules.summaryText(for: checkpoint))
                    Spacer()
                    Button("Return") { checkpointToRestore = checkpoint }
                        .accessibilityIdentifier("button.checkpoint.restore")
                    Button("Remove") { model.removeCheckpoint(id: checkpoint.id) }
                        .accessibilityIdentifier("button.checkpoint.remove")
                }
            }
            Button("Save checkpoint…") { showCheckpointComposer = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("button.addCheckpoint")
        }
        .sheet(isPresented: $showCheckpointComposer) {
            CheckpointComposer(isPresented: $showCheckpointComposer)
        }
        .alert("Return to checkpoint?", isPresented: Binding(
            get: { checkpointToRestore != nil },
            set: { if !$0 { checkpointToRestore = nil } }
        )) {
            Button("Apply correction", role: .destructive) {
                if let checkpoint = checkpointToRestore {
                    model.restoreCheckpoint(checkpoint.id, confirmed: true)
                }
                checkpointToRestore = nil
            }
            .accessibilityIdentifier("button.confirmRestoreCheckpoint")
            Button("Cancel", role: .cancel) { checkpointToRestore = nil }
        } message: {
            if let checkpoint = checkpointToRestore {
                Text("\(CheckpointRules.summaryText(for: checkpoint)). Current completed rows: \(piece.completedRows). Repeat settings stay unchanged. \(CheckpointRules.restoreExplanation)")
            }
        }
    }

    private func historySection(piece: PieceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Row history") { showHistory = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("button.showHistory")
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                List {
                    ForEach(model.rowHistory) { event in
                        Text("\(event.sequence). \(event.kind.rawValue) · \(event.before) → \(event.after)")
                            .accessibilityIdentifier("history.timeline")
                    }
                }
                .navigationTitle("Row history")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showHistory = false }
                    }
                }
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

private struct CounterComposer: View {
    @Environment(WorkspaceModel.self) private var model
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var unit = ""
    @State private var startingValue = "0"
    @State private var repeatLength = ""
    @State private var linked = false
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Counter name (e.g. Sleeves, Cable motif)", text: $name)
                    .accessibilityIdentifier("field.counter.name")
                TextField("Unit (optional, e.g. rows, repeats)", text: $unit)
                    .accessibilityIdentifier("field.counter.unit")
                TextField("Starting value", text: $startingValue)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("field.counter.start")
                TextField("Repeat length (optional)", text: $repeatLength)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("field.counter.repeat")
                Toggle("Advance with Complete row", isOn: $linked)
                    .accessibilityIdentifier("toggle.counter.composerLink")
                Text("Extra counters are piece-specific. Linked counters advance atomically whenever Complete row is tapped; unlinked counters advance only when their own button is tapped.")
                if let validationMessage { Text(validationMessage) }
            }
            .navigationTitle("Add extra counter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let start = Int(startingValue) ?? 0
                        let repeatLen = repeatLength.isEmpty ? nil : Int(repeatLength)
                        model.lastError = nil
                        model.addCounter(name: name, unit: unit, startingValue: start,
                                         repeatLength: repeatLen, linked: linked)
                        if let error = model.lastError {
                            validationMessage = error.userMessage
                        } else {
                            isPresented = false
                        }
                    }
                    .accessibilityIdentifier("button.counter.save")
                }
            }
        }
    }
}

private struct CheckpointComposer: View {
    @Environment(WorkspaceModel.self) private var model
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Checkpoint name", text: $name)
                    .accessibilityIdentifier("field.checkpoint.name")
                Text("Saves the current completed-row count for this piece. Returning later changes only the recorded count, not physical work or repeat settings.")
                if let validationMessage { Text(validationMessage) }
            }
            .navigationTitle("Save checkpoint")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.lastError = nil
                        model.addCheckpoint(name: name)
                        if let error = model.lastError {
                            validationMessage = error.userMessage
                        } else { isPresented = false }
                    }
                    .accessibilityIdentifier("button.checkpoint.save")
                }
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

// MARK: - Details editor (issue #20)

/// Edits project defaults and the selected piece's overrides. All fields are
/// optional; entries are parsed in the chosen display unit and saved as
/// canonical metric. Unparseable numbers block Save and are never coerced.
private struct DetailsEditor: View {
    @Environment(WorkspaceModel.self) private var model
    @Binding var isPresented: Bool
    @State private var scopeIsPiece = false
    @State private var imperial = false
    @State private var material = ""
    @State private var colorway = ""
    @State private var size = ""
    @State private var tool = ""
    @State private var stitches = ""
    @State private var rows = ""
    @State private var measurement = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Applies to", selection: $scopeIsPiece) {
                    Text("Whole project").tag(false)
                    Text("This piece only").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("details.scope")
                .onChange(of: scopeIsPiece) { _, _ in load() }
                Toggle("Show imperial units", isOn: $imperial)
                    .accessibilityIdentifier("details.imperial")
                    .onChange(of: imperial) { _, _ in
                        // Presentation only: stored metric values are reloaded and re-rendered.
                        model.setImperialDisplay(imperial)
                        load()
                    }
                if scopeIsPiece {
                    Text("Blank fields use the project value.")
                        .font(.footnote)
                }
                TextField("Yarn or material", text: $material).accessibilityIdentifier("details.material")
                TextField("Colorway", text: $colorway).accessibilityIdentifier("details.colorway")
                TextField("Selected size", text: $size).accessibilityIdentifier("details.size")
                TextField(imperial ? "Needle or hook size (in)" : "Needle or hook size (mm)", text: $tool)
                    .keyboardType(.decimalPad).accessibilityIdentifier("details.tool")
                TextField(imperial ? "Stitches per 4 in" : "Stitches per 10 cm", text: $stitches)
                    .keyboardType(.decimalPad).accessibilityIdentifier("details.stitches")
                TextField(imperial ? "Rows per 4 in" : "Rows per 10 cm", text: $rows)
                    .keyboardType(.decimalPad).accessibilityIdentifier("details.rows")
                TextField(imperial ? "Measurement (in)" : "Measurement (mm)", text: $measurement)
                    .keyboardType(.decimalPad).accessibilityIdentifier("details.measurement")
            }
            .navigationTitle("Project details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isPresented = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(draft() == nil)
                        .accessibilityIdentifier("details.save")
                }
            }
            .onAppear { imperial = model.usesImperialDisplay; load() }
        }
    }

    private func load() {
        let details = scopeIsPiece ? model.pieceDetails : model.projectDetails
        material = details.material; colorway = details.colorway; size = details.selectedSize
        tool = text(details.toolSizeMM.map { imperial ? ProjectDetails.inches(fromMM: $0) : $0 })
        stitches = text(details.gaugeStitchesPer10CM.map { imperial ? ProjectDetails.countPer4Inches(fromPer10CM: $0) : $0 })
        rows = text(details.gaugeRowsPer10CM.map { imperial ? ProjectDetails.countPer4Inches(fromPer10CM: $0) : $0 })
        measurement = text(details.measurementMM.map { imperial ? ProjectDetails.inches(fromMM: $0) : $0 })
    }

    private func text(_ value: Double?) -> String { value.map { String($0) } ?? "" }

    /// nil when any non-blank number fails to parse.
    private func parse(_ string: String) -> Double?? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .some(nil) }
        guard let value = Double(trimmed) else { return nil }
        return .some(value)
    }

    private func draft() -> ProjectDetails? {
        guard let t = parse(tool), let s = parse(stitches), let r = parse(rows), let m = parse(measurement) else { return nil }
        let details = ProjectDetails(
            material: material.trimmingCharacters(in: .whitespacesAndNewlines),
            colorway: colorway.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedSize: size.trimmingCharacters(in: .whitespacesAndNewlines),
            toolSizeMM: t.map { imperial ? ProjectDetails.mm(fromInches: $0) : $0 },
            gaugeStitchesPer10CM: s.map { imperial ? ProjectDetails.countPer10CM(fromPer4Inches: $0) : $0 },
            gaugeRowsPer10CM: r.map { imperial ? ProjectDetails.countPer10CM(fromPer4Inches: $0) : $0 },
            measurementMM: m.map { imperial ? ProjectDetails.mm(fromInches: $0) : $0 })
        return details.isValid ? details : nil
    }

    private func save() {
        guard let details = draft() else { return }
        if scopeIsPiece { model.savePieceDetails(details) } else { model.saveProjectDetails(details) }
        isPresented = false
    }
}
