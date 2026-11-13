import SwiftUI

/// Settings › About › Changelog: every change the app has shipped, on one
/// scrolling screen, newest first. Unreleased leads when it lists anything,
/// then each release under its version and date. Release bodies are drawn
/// by the help pages' Markdown renderer, issue and PR references removed;
/// a `/help/<slug>` link pushes that help page, anything else goes to the
/// system. The same list is public at waycar.dev/changelog.
struct ChangelogView: View {
    static let webURL = HelpWeb.base.appending(path: "changelog")

    @State private var document: ChangelogDocument?
    @State private var tableOffsets = ChangelogTableOffsets()
    @State private var helpCatalog: HelpCatalog?
    @State private var pushedHelp: HelpPageView.Route?
    @Environment(\.openURL) private var systemOpenURL

    var body: some View {
        Group {
            if let document {
                if document.rows.isEmpty {
                    ContentUnavailableView {
                        Label("Changelog Unavailable", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("The changelog couldn't be loaded.")
                    } actions: {
                        Link("Open waycar.dev/changelog", destination: Self.webURL)
                    }
                } else {
                    list(document)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Changelog")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Open on waycar.dev", systemImage: "safari") {
                    systemOpenURL(Self.webURL)
                }
                .accessibilityIdentifier("changelog.openWeb")
                ShareLink(item: Self.webURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("changelog.share")
            }
        }
        .navigationDestination(item: $pushedHelp) { route in
            if let helpCatalog {
                HelpPageView(page: route.page, catalog: helpCatalog, anchor: route.anchor)
            }
        }
        .task {
            guard document == nil else { return }
            document = await ChangelogLibrary.document()
        }
    }

    private func list(_ document: ChangelogDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.rows) { row in
                    switch row {
                    case .heading(let entry, let isFirst):
                        ChangelogHeading(entry: entry, isFirst: isFirst)
                    case .markdown(let entryID, let markdownRow):
                        MarkdownRowView(row: markdownRow, tableOffsets: tableOffsets.offsets(for: entryID))
                    }
                }
            }
            // As on a help page: selecting is a long press, a tap on a link
            // still opens it.
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: MarkdownDocumentView.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("changelog.list")
    }

    private func open(_ url: URL) {
        switch HelpLinkDestination.resolve(url) {
        case .page(let slug, let anchor):
            Task { await openHelpPage(slug, anchor: anchor) }
        case .external(let external):
            systemOpenURL(external)
        case .anchor, nil:
            // Headings repeat from release to release: no anchor is unique.
            break
        }
    }

    private func openHelpPage(_ slug: String, anchor: String?) async {
        if let catalog = await HelpLibrary.catalog(), let page = catalog.page(slug) {
            helpCatalog = catalog
            pushedHelp = HelpPageView.Route(page: page, anchor: anchor)
        } else if let webURL = HelpWeb.pageURL(slug) {
            systemOpenURL(webURL)
        }
    }
}

/// A section's heading: the version (or Unreleased) over its date (or when
/// it ships), read by VoiceOver as one heading. A rule sets each section
/// after the first apart from the one above.
private struct ChangelogHeading: View {
    let entry: ChangelogEntry
    let isFirst: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                Divider()
                    .padding(.top, 32)
                    .padding(.bottom, 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(.title2, weight: .semibold))
                Text(entry.subtitle())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(.h2)
            .accessibilityIdentifier("changelog.section.\(entry.id)")
        }
    }
}

/// Each section's wide-table offsets: table ids repeat from one section's
/// document to the next. Not observed, like the offsets it holds.
@MainActor
private final class ChangelogTableOffsets {
    private var bySection: [String: MarkdownTableScrollOffsets] = [:]

    func offsets(for entryID: String) -> MarkdownTableScrollOffsets {
        if let offsets = bySection[entryID] {
            return offsets
        }
        let offsets = MarkdownTableScrollOffsets()
        bySection[entryID] = offsets
        return offsets
    }
}
