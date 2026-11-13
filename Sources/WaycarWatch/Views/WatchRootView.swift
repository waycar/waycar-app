import SwiftUI

// MARK: - Root

/// The watch app's root: W1 in a `NavigationStack` whose path is the
/// store's route, so deep links and notification taps push W2, W3, or W4.
struct WatchRootView: View {
    /// The watch's model; its `route` drives the navigation path.
    @Bindable var store: WatchStore
    /// The one voice recorder W4 drives.
    let recorder: WatchRecorder

    /// The stack.
    var body: some View {
        NavigationStack(path: $store.route) {
            AgentListView(store: store)
                .navigationDestination(for: WatchStore.Route.self) { route in
                    destination(for: route)
                }
        }
        .tint(WatchBrand.Colors.accent)
    }

    /// The screen for one route.
    @ViewBuilder
    private func destination(for route: WatchStore.Route) -> some View {
        switch route {
        case .agent(let agentID):
            AgentDetailView(agentID: agentID, store: store)
        case .blocked(let agentID):
            BlockedDetailView(agentID: agentID, store: store)
        case .recorder(let agentID):
            RecorderView(agentID: agentID, store: store, recorder: recorder)
        }
    }
}
