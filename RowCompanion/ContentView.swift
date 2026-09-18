import SwiftUI

struct ContentView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Row Companion")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("workspace.title")
                Text("Your pattern and row workspace")
                    .font(.title2)
                Text("Project setup, pattern import, and row counting are coming next. This development build verifies app launch only.")
                    .accessibilityIdentifier("workspace.status")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
