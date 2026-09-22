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
            let url = RowStoreFactory.defaultStoreURL()
            // UI-test isolation: an explicit launch argument wipes the
            // app-private workspace before opening, so journeys start from a
            // clean store. Never triggered by normal app launches.
            if CommandLine.arguments.contains("-rc-ui-tests-reset") {
                let base = url.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: base)
            }
            let repository = try RowRepository.openOrCreate(storeURL: url)
            model = .success(WorkspaceModel(repository: repository))
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
