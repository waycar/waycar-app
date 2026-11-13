import SwiftUI

/// Host detail's Backends section only controls runtime visibility.
/// Launch destinations are chosen in New Agent, never in Host settings.
struct HostBackendsSection: View {
    let store: HostOnboardingStore
    let console: ConsoleStore

    var body: some View {
        if (store.resolvedBackends?.count ?? 0) > 1
            || store.resolvedBackends?.contains(where: \.isServerChat) == true
            || store.hasZellij
        {
            let hostID = store.host.id
            Section {
                ForEach(
                    HerdrRuntime.allCases.filter { store.resolvedBackends?.contains($0.backend) == true },
                    id: \.self
                ) { runtime in
                    Toggle(
                        "Show \(runtime.displayName) sessions",
                        isOn: Binding(
                            get: { console.backendPreferences.showsRuntime(runtime, for: hostID) },
                            set: { shows in
                                Task {
                                    await console.setShowsRuntime(shows, runtime: runtime, for: hostID)
                                }
                            }))
                }
                if store.isDualBackend {
                    Toggle(
                        "Show tmux sessions",
                        isOn: Binding(
                            get: { console.backendPreferences.showsTmux(for: hostID) },
                            set: { shows in
                                Task { await console.setShowsTmux(shows, for: hostID) }
                            }))
                }
                if store.hasZellij {
                    Toggle("Show Zellij sessions", isOn: Binding(
                        get: { console.backendPreferences.showsZellij(for: hostID) },
                        set: { shows in Task { await console.setShowsZellij(shows, for: hostID) } }))
                }
                ForEach(
                    ServerChatBackend.allCases.filter { store.resolvedBackends?.contains($0.backend) == true },
                    id: \.self
                ) { server in
                    Toggle(
                        "Show \(server.sessionDescription)s",
                        isOn: Binding(
                            get: { console.backendPreferences.showsServerChat(server, for: hostID) },
                            set: { console.setShowsServerChat($0, server, for: hostID) }))
                }
            } header: {
                Text("Backends")
            } footer: {
                if store.hasZellij {
                    Text("Hiding Zellij sessions also stops their notifications from this Host.")
                } else if store.isDualBackend {
                    Text("Hiding tmux sessions also stops their notifications from this Host.")
                }
            }
        }
    }
}
