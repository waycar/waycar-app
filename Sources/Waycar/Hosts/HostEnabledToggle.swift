import SwiftUI

/// The switch that turns a Host on or off (Disabled Host, CONTEXT.md). The
/// Hosts row and the Host page share it.
struct HostEnabledToggle: View {
    let host: Host
    let catalog: HostStore

    var body: some View {
        Toggle("Enabled", isOn: Binding(
            get: { host.isEnabled },
            set: { catalog.setHostEnabled($0, for: host.id) }))
    }
}
