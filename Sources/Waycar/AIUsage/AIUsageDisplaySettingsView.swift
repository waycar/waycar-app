import SwiftUI

/// Settings › CodexBar: how AI Usage is displayed, app-wide. Which Hosts
/// are asked, how often, and where CodexBar lives stay on each Host's page.
struct AIUsageDisplaySettingsView: View {
    let store: AIUsageStore

    private var preferences: AIUsagePreferences { store.preferences }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<AIUsageDisplayOptions, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences.display[keyPath: keyPath] },
            set: { value in
                var options = preferences.display
                options[keyPath: keyPath] = value
                preferences.updateDisplay(options)
            })
    }

    /// Providers in the latest reports, plus a remembered choice no longer
    /// reported, so the picker never loses its selection.
    private var providerChoices: [(id: String, name: String)] {
        var choices = store.reportedProviders
        if let chosen = preferences.display.pillProviderID,
            !choices.contains(where: { $0.id == chosen })
        {
            choices.append((id: chosen, name: AIUsageReport.displayName(forProviderID: chosen)))
        }
        return choices
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: binding(\.pillProviderID)) {
                    Text("Most Urgent").tag(String?.none)
                    ForEach(providerChoices, id: \.id) { choice in
                        Text(choice.name).tag(String?.some(choice.id))
                    }
                }
                Picker("Window", selection: binding(\.pillWindow)) {
                    ForEach(AIUsagePillWindow.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Reset Time", isOn: binding(\.pillShowsResetTime))
            } header: {
                Text("Console Summary")
            } footer: {
                Text(
                    "Most Urgent names the provider closest to its limit. A chosen provider "
                        + "missing from the latest report falls back to the most urgent one. "
                        + "Session + Weekly shows the session number, then the weekly one. "
                        + "Other windows mark their number S (session) or W (weekly). "
                        + "The reset time is the first number's.")
            }

            Section {
                Picker("Show Usage As", selection: binding(\.showsUsed)) {
                    Text("Remaining").tag(false)
                    Text("Used").tag(true)
                }
                Picker("Reset Times", selection: binding(\.resetStyle)) {
                    ForEach(AIUsageResetStyle.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Colors always reflect what is left.")
            }

            Section {
                Toggle("Show Pace", isOn: binding(\.showsPace))
                Toggle("Hide Account Labels", isOn: binding(\.hidesAccountLabels))
                Toggle("Refresh When Opened", isOn: binding(\.refreshesWhenOpened))
            } header: {
                Text("Usage Details")
            } footer: {
                Text(
                    "Pace marks how much should be used by now to last until the reset, and "
                        + "each gauge reads out CodexBar's estimate: in reserve when you are "
                        + "using it slower, in deficit — with how long it will last — when you "
                        + "are on track to run out first. "
                        + "Refresh When Opened asks a live Host when you expand AI Usage in the "
                        + "Console or open its details, unless it answered in the last 30 seconds. "
                        + "Each Host's page has its own options: whether to use CodexBar (on for "
                        + "one Host by default), how often to refresh, and a custom path.")
            }
        }
        .navigationTitle("CodexBar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { HelpLink(.aiUsage) } }
    }
}
