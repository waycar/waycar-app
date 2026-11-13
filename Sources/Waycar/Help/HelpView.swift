import SwiftUI

/// Settings › Help (and the ⌘? sheet): the bundled waycar.dev help pages by
/// category, searched offline.
///
/// Rows push by value, so the presenting `NavigationStack` must reach this
/// view by value too (or have it as its root): a value pushed over a
/// view-destination link pops that link, taking Help and its query with it.
struct HelpView: View {
    @State private var catalog: HelpCatalog?
    @State private var isLoading = true
    @State private var query = ""

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let catalog {
                list(catalog)
            } else {
                ContentUnavailableView {
                    Label("Help Unavailable", systemImage: "questionmark.circle")
                } description: {
                    Text("The help pages couldn't be loaded.")
                } actions: {
                    Link("Open waycar.dev/help", destination: HelpWeb.base.appending(path: "help"))
                }
            }
        }
        // On the root, not the List in the branch above: from there, on
        // iPhone, Back from a page lost the search bar (and with a search
        // active, the whole navigation bar).
        .searchable(
            text: $query, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search Help")
        .navigationTitle("Help")
        .accessibilityIdentifier("help.list")
        .navigationDestination(for: HelpPage.self) { page in
            if let catalog {
                HelpPageView(page: page, catalog: catalog)
            }
        }
        .task {
            guard isLoading else { return }
            catalog = await HelpLibrary.catalog()
            isLoading = false
        }
    }

    private func list(_ catalog: HelpCatalog) -> some View {
        let results = catalog.search(query)
        let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return List {
            if isSearching {
                ForEach(results) { page in row(page) }
            } else {
                ForEach(catalog.categories) { category in
                    let pages = catalog.pages(in: category.id)
                    if !pages.isEmpty {
                        Section(category.label) {
                            ForEach(pages) { page in row(page) }
                        }
                    }
                }
            }
        }
        .overlay {
            if isSearching && results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func row(_ page: HelpPage) -> some View {
        NavigationLink(value: page) {
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                Text(page.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityIdentifier("help.row.\(page.slug)")
    }
}
