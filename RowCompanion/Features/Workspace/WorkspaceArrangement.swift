import Foundation

/// Pure arrangement rules for the workspace (issue #4). Deliberately free of
/// SwiftUI/UIKit/SwiftData imports: the layout seam reads exactly these two
/// environment facts (regular width? accessibility text size?) and nothing
/// else, and this file provably has no path to `RowAction` — reflowing from
/// two-pane to stacked (or back) can never create a row event.

/// Which side the reference occupies in the wide (regular-width) layout.
/// Reversible on demand; it is *view arrangement only* and is never
/// persisted, so a reorder cannot disturb durable state.
public enum WorkspacePaneOrder: String, Equatable, Sendable {
    case referenceFirst
    case controlsFirst
}

public enum WorkspaceArrangement {
    /// Two panes require regular width AND a readable Dynamic Type size:
    /// at accessibility text sizes the side pane would truncate the
    /// reference/counter content, so the layout falls back to stacked.
    public static func useTwoPane(regularWidth: Bool, isAccessibilitySize: Bool) -> Bool {
        regularWidth && !isAccessibilitySize
    }

    public static func flipped(_ order: WorkspacePaneOrder) -> WorkspacePaneOrder {
        order == .referenceFirst ? .controlsFirst : .referenceFirst
    }

    /// Explicit, documented future seam for a dual-screen (iPhone Duo class)
    /// adapter: a later host would feed two window scenes plus their safe
    /// regions into `WorkspaceArrangement`/`WorkspaceLayout` and map
    /// `referenceFirst` to the display holding the chart. No hinge-sensor,
    /// fold-state, or other unavailable SDK API is required or referenced
    /// here, and no physical dual-screen compatibility is claimed today.
    public static let futureDualScreenAdapterNote =
        "Future iPhone Duo design target: an external adapter supplies two scenes and safe regions; this app never depends on fold SDK APIs."
}
