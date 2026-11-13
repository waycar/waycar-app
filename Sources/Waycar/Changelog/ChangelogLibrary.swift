import Foundation

/// One row of the Changelog screen: a section's heading, or one row of its
/// Markdown, so a single lazy stack lays out only what is on screen however
/// far back the reader scrolls.
enum ChangelogRow: Identifiable, Sendable {
    case heading(ChangelogEntry, isFirst: Bool)
    /// `entryID` names the section the row belongs to: row ids repeat from
    /// one section's document to the next.
    case markdown(entryID: String, MarkdownDocumentRow)

    var id: String {
        switch self {
        case .heading(let entry, _): entry.id
        case .markdown(let entryID, let row): "\(entryID)#\(row.id)"
        }
    }
}

/// The whole changelog as rows: each entry's heading, then its body parsed
/// by the same Markdown pipeline as the help pages.
struct ChangelogDocument: Sendable {
    let rows: [ChangelogRow]

    init(_ catalog: ChangelogCatalog) {
        var rows: [ChangelogRow] = []
        for (index, entry) in catalog.entries.enumerated() {
            rows.append(.heading(entry, isFirst: index == 0))
            let markdown = MarkdownDocumentRows(MarkdownDocument.parse(entry.body))
            rows.append(contentsOf: markdown.rows.map { .markdown(entryID: entry.id, $0) })
        }
        self.rows = rows
    }
}

/// The bundled changelog, read and parsed once per process off the main
/// actor, like ``HelpLibrary``: no screen pays for it during its first
/// render. Concurrent callers share the one load. Empty rows when nothing
/// in the bundle could be read; the screen then points at waycar.dev.
enum ChangelogLibrary {
    @MainActor private static var load: Task<ChangelogDocument, Never>?

    @MainActor static func document() async -> ChangelogDocument {
        if let load {
            return await load.value
        }
        let task = Task.detached(priority: .userInitiated) { ChangelogDocument(ChangelogCatalog.bundled()) }
        load = task
        return await task.value
    }
}
