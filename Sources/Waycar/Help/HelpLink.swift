import SwiftUI

/// A contextual "Learn More" link to one help page, presented in its own
/// sheet so it works from any screen, inside a `NavigationStack` or not.
/// Put it in a Form section footer or a toolbar.
///
/// The catalogue is resolved on tap, never while rendering. Pass `action`
/// when the host screen owns the presentation (so it can count it as
/// covering its keyboard commands); it then resolves via `HelpPresentation`.
struct HelpLink: View {
    let topic: HelpTopic
    var action: (() -> Void)?

    @State private var presentation: HelpPresentation?
    @Environment(\.openURL) private var openURL

    init(_ topic: HelpTopic, action: (() -> Void)? = nil) {
        self.topic = topic
        self.action = action
    }

    var body: some View {
        Button {
            if let action {
                action()
            } else {
                Task {
                    await HelpPresentation.open(topic, openURL: openURL) { presentation = $0 }
                }
            }
        } label: {
            Label("Learn More", systemImage: "questionmark.circle")
        }
        .accessibilityLabel("Learn More")
        .accessibilityHint("Opens help for this screen")
        .accessibilityIdentifier("help.link.\(topic.rawValue)")
        .sheet(item: $presentation) { presentation in
            HelpPresentationSheet(presentation: presentation) { self.presentation = nil }
        }
    }
}

/// One resolved help page, ready for a sheet.
struct HelpPresentation: Identifiable {
    let page: HelpPage
    let catalog: HelpCatalog
    var id: String { page.id }

    /// Resolves `topic` against the bundled catalogue and hands the page to
    /// `present`; opens it on waycar.dev when the bundle lacks it.
    @MainActor
    static func open(
        _ topic: HelpTopic, openURL: OpenURLAction,
        present: (HelpPresentation) -> Void
    ) async {
        if let catalog = await HelpLibrary.catalog(), let page = catalog.page(topic.rawValue) {
            present(HelpPresentation(page: page, catalog: catalog))
        } else if let webURL = HelpWeb.pageURL(topic.rawValue) {
            openURL(webURL)
        }
    }
}

struct HelpPresentationSheet: View {
    let presentation: HelpPresentation
    let done: () -> Void

    var body: some View {
        NavigationStack {
            HelpPageView(page: presentation.page, catalog: presentation.catalog)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                            .accessibilityIdentifier("help.page.done")
                    }
                }
        }
    }
}
