import SwiftUI

@main
struct RowCompanionApp: App {
    /// One repository per app process — the single durable state owner. The
    /// store lives in app-private Application Support (CloudKit disabled by
    /// `RowStoreFactory`); a failure to open it is surfaced, never papered
    /// over with an in-memory stand-in that would fake durability.
    private let model: Result<WorkspaceModel, Error>

    init() {
        do {
            var url = RowStoreFactory.defaultStoreURL()
            #if DEBUG && targetEnvironment(simulator)
            // Marketing fixtures use a separate simulator-only store. Real
            // projects and the release build never enter this path.
            let screenshots = CommandLine.arguments.contains("-rc-app-store")
            if screenshots {
                url = url.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("RowCompanionScreenshots")
                    .appendingPathComponent("screenshots.sqlite")
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            #endif
            // UI-test isolation: an explicit launch argument wipes the
            // app-private workspace before opening, so journeys start from a
            // clean store. Never triggered by normal app launches.
            if CommandLine.arguments.contains("-rc-ui-tests-reset") {
                let base = url.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: base)
            }
            let repository = try RowRepository.openOrCreate(storeURL: url)
            let workspace = WorkspaceModel(repository: repository)
            #if DEBUG && targetEnvironment(simulator)
            if screenshots { try seedAppStoreWorkspace(workspace) }
            #endif
            model = .success(workspace)
        } catch {
            model = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch model {
            case .success(let workspace):
                ContentView()
                    .environment(workspace)
            case .failure(let error):
                StartupFailureView(error: error)
            }
        }
    }
}

/// Honest fail-closed startup screen: the store could not be opened, so no
/// editable workspace exists. Users get an actionable message, not a fake
/// empty app whose data would silently vanish.
struct StartupFailureView: View {
    let error: Error
    var body: some View {
        VStack(spacing: 12) {
            Text("Row Companion")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("workspace.title")
            Text("The local data store could not be opened, so your projects cannot be shown safely.")
                .font(.body)
            Text(String(describing: error))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("workspace.status")
        }
        .padding()
    }
}

#if DEBUG && targetEnvironment(simulator)
import UIKit

/// Original sample content for repeatable captures of the real interface.
@MainActor
private func seedAppStoreWorkspace(_ workspace: WorkspaceModel) throws {
    workspace.createProject(title: "Weekend cardigan")
    workspace.addPiece(name: "Back panel", repeatLength: 8)
    let back = workspace.selectedPieceID
    for _ in 0..<42 { workspace.completeRow() }
    workspace.setNotes("Moss stitch panel · 5 mm needles\nWork 8-row repeats to desired length.\nPlace a marker at the beginning of each repeat.")

    let page = CGRect(x: 0, y: 0, width: 420, height: 360)
    let pdf = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
        context.beginPage()
        UIColor(red: 0.98, green: 0.96, blue: 0.93, alpha: 1).setFill()
        context.cgContext.fill(page)
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, bold: Bool = false) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                .foregroundColor: UIColor(red: 0.19, green: 0.13, blue: 0.28, alpha: 1)
            ])
        }
        text("WEEKEND CARDIGAN", 28, 20, 12, bold: true)
        text("Moss stitch study", 28, 42, 27, bold: true)
        text("8-row repeat • work flat", 28, 80, 13)
        let cell: CGFloat = 23
        for row in 0..<8 {
            text(String(8 - row), 28, 113 + CGFloat(row) * cell, 12)
            for column in 0..<14 {
                let rect = CGRect(x: 49 + CGFloat(column) * cell, y: 108 + CGFloat(row) * cell, width: cell, height: cell)
                let purl = (column + (row / 2)) % 2 == 0
                (purl ? UIColor(red: 0.89, green: 0.83, blue: 0.93, alpha: 1) : .white).setFill()
                context.cgContext.fill(rect)
                UIColor(white: 0.65, alpha: 1).setStroke()
                context.cgContext.setLineWidth(0.5)
                context.cgContext.stroke(rect)
                if purl { text("•", rect.minX + 8, rect.minY + 2, 15) }
            }
        }
        text("□ Knit on RS / purl on WS    • Purl on RS / knit on WS", 28, 306, 12)
    }
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("row-companion-sample.pdf")
    try pdf.write(to: fixture)
    defer { try? FileManager.default.removeItem(at: fixture) }
    workspace.importPDF(from: fixture)
    workspace.setGuide(y: 0.70)
    workspace.addPiece(name: "Left sleeve", repeatLength: 8)
    for _ in 0..<20 { workspace.completeRow() }
    workspace.setNotes("5 mm needles · moss stitch\nCompare with the right sleeve before shaping.\nKeep both sleeves at the same length.")
    workspace.viewerMoved(pageIndex: 0, visibleRect: .full)
    workspace.setGuide(y: 0.56)
    if !CommandLine.arguments.contains("-rc-app-store-sleeve") { workspace.select(piece: back) }
    if let error = workspace.lastError { throw error }
}
#endif
