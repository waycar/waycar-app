import SwiftUI

/// One bundled help page drawn natively with the app's Markdown renderer.
///
/// The title is the navigation bar's large title; the lead and body are one
/// Markdown document, followed by Related as native navigation rows in the
/// same scroll. On the first help pages opened on this device, a labelled
/// Ask an Agent button sits above the lead to teach the toolbar's icon
/// (`AskAgentHint`). A `/help/<slug>` link pushes that page (scrolled to its
/// `#anchor`), a bare `#anchor` scrolls this one, and anything else goes to
/// the system. The content is first-party, so no link asks first.
///
/// Pushes are state-driven (`navigationDestination(item:)`), never by value,
/// so a page works in any stack: under `HelpView`, or as a sheet's root.
struct HelpPageView: View {
    let page: HelpPage
    let catalog: HelpCatalog
    /// Heading to bring to the top on open, as slugged by `MarkdownDocument.slug`.
    let anchor: String?

    @State private var rows: MarkdownDocumentRows
    @State private var scrollTarget: MarkdownDocumentRow.ID?
    @State private var pushed: Route?
    /// The opening anchor is scrolled to once: coming Back to this page
    /// keeps the reader's place.
    @State private var didScrollToAnchor = false
    /// Decided once per view, like the anchor: coming Back doesn't count
    /// the page again or change whether it shows the button.
    @State private var askAgentHint = AskAgentHint()
    @Environment(\.openURL) private var systemOpenURL
    @Environment(\.askAgent) private var askAgent

    init(page: HelpPage, catalog: HelpCatalog, anchor: String? = nil) {
        self.page = page
        self.catalog = catalog
        self.anchor = anchor
        _rows = State(
            initialValue: MarkdownDocumentRows(MarkdownDocument.parse(Self.markdown(for: page))))
    }

    var body: some View {
        MarkdownDocumentView(
            rows: rows, scrollTarget: $scrollTarget,
            header: AnyView(askAgentHintSection), footer: AnyView(relatedSection)
        )
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("help.page.\(page.slug)")
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarItems }
        .navigationDestination(item: $pushed) { route in
            HelpPageView(page: route.page, catalog: catalog, anchor: route.anchor)
        }
        .task {
            guard !didScrollToAnchor else { return }
            didScrollToAnchor = true
            guard let anchor, let row = rows.rowID(forAnchor: anchor) else { return }
            scrollTarget = row
        }
        .task(id: askAgent != nil) {
            askAgentHint.pageAppeared(canAskAgent: askAgent != nil)
        }
    }

    /// The toolbar's Ask an Agent as a labelled button, for the first
    /// `AskAgentHint.limit` page views, so the icon gets learned.
    @ViewBuilder
    private var askAgentHintSection: some View {
        if let askAgent, askAgentHint.isVisible {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    askAgent(HelpAgentPrompt.preset(for: page))
                } label: {
                    Label("Ask an Agent", systemImage: "plus.bubble")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: Brand.Radius.controlLg))
                .controlSize(.large)
                // A sheet doesn't take the app root's tint.
                .tint(Brand.Colors.accent)
                .accessibilityLabel("Ask an agent about this page")
                .accessibilityIdentifier("help.page.askAgentInline")
                Text(
                    "Start an agent that reads this page with you. "
                        + "Later, use the speech bubble with a plus in the bar at the top.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "Start an agent that reads this page with you. "
                            + "The Ask an Agent button in the top bar does the same.")
            }
            .padding(.bottom, 20)
        }
    }

    /// Related pages as buttons that push, so VoiceOver and UI tests find
    /// them as buttons rather than links inside the text.
    @ViewBuilder
    private var relatedSection: some View {
        let related = page.related.compactMap { catalog.page($0) }
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Related")
                    .font(.system(.title2, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHeading(.h2)
                    .padding(.top, 24)
                    .padding(.bottom, 4)
                ForEach(related) { target in
                    Divider()
                    Button {
                        pushed = Route(page: target, anchor: nil)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.title)
                                    .foregroundStyle(.primary)
                                Text(target.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("help.related.\(target.slug)")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if let webURL = HelpWeb.pageURL(page.slug) {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Open on waycar.dev", systemImage: "safari") {
                    systemOpenURL(webURL)
                }
                .accessibilityIdentifier("help.page.openWeb")
                ShareLink(item: webURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("help.page.share")
            }
        }
        if let askAgent {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ask an Agent", systemImage: "plus.bubble") {
                    askAgent(HelpAgentPrompt.preset(for: page))
                }
                .accessibilityLabel("Ask an agent about this page")
                .accessibilityIdentifier("help.page.askAgent")
            }
        }
    }

    private func open(_ url: URL) {
        switch HelpLinkDestination.resolve(url) {
        case .page(let slug, let anchor):
            if slug == page.slug {
                if let anchor { scrollTo(anchor) }
            } else if let target = catalog.page(slug) {
                pushed = Route(page: target, anchor: anchor)
            } else if let webURL = HelpWeb.pageURL(slug) {
                // A page this build doesn't bundle yet still lives on the site.
                systemOpenURL(webURL)
            }
        case .anchor(let anchor):
            scrollTo(anchor)
        case .external(let external):
            systemOpenURL(external)
        case nil:
            break
        }
    }

    private func scrollTo(_ anchor: String) {
        // A heading the page lacks makes a dead link: nothing to do.
        if let row = rows.rowID(forAnchor: anchor) {
            scrollTarget = row
        }
    }

    /// The page as one Markdown document: lead, then body. The title is the
    /// navigation bar's, and Related is drawn natively after the document.
    nonisolated static func markdown(for page: HelpPage) -> String {
        guard !page.description.isEmpty else { return page.body }
        return "*\(page.description)*\n\n\(page.body)"
    }

    struct Route: Hashable, Identifiable {
        let page: HelpPage
        let anchor: String?
        var id: Self { self }
    }
}
