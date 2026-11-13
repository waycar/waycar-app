import Foundation

/// A release's version: `major.minor.patch`, each a decimal number without
/// leading zeros, ordered numerically (1.10.0 is above 1.9.0).
struct ChangelogVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    /// Nil unless `text` is exactly three dot-separated numbers.
    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                part == "0" || part.first != "0",
                let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// One section of the changelog: the upcoming release, or a shipped one.
struct ChangelogEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// `CHANGELOG.md`'s `[Unreleased]` section.
        case unreleased
        /// `date` is midnight UTC of the release day.
        case release(ChangelogVersion, date: Date)
    }

    let kind: Kind
    /// The section's Markdown, issue and PR references removed
    /// (``ChangelogCatalog/strippingReferences(_:)``).
    let body: String

    var id: String {
        switch kind {
        case .unreleased: "unreleased"
        case .release(let version, _): version.description
        }
    }

    var title: String {
        switch kind {
        case .unreleased: "Unreleased"
        case .release(let version, _): "Version \(version)"
        }
    }

    /// The release day written out ("October 4, 2026"); for Unreleased, a
    /// line saying it is still to ship.
    func subtitle(locale: Locale = .current) -> String {
        switch kind {
        case .unreleased:
            "Coming in the next update."
        case .release(_, let date):
            date.formatted(
                Date.FormatStyle(
                    date: .long, time: .omitted, locale: locale, calendar: ChangelogCatalog.calendar,
                    timeZone: ChangelogCatalog.calendar.timeZone))
        }
    }
}

/// The changelog the app bundles: every release file of
/// `apps/web/src/content/changelog` (bundled as `changelog/`, the files
/// waycar.dev/changelog renders) and the `[Unreleased]` section of the root
/// `CHANGELOG.md`. Unreleased comes first when it lists any change, then
/// the releases, newest version first.
struct ChangelogCatalog: Sendable {
    /// Bundle subdirectory holding one `<version>.md` per release.
    static let subdirectory = "changelog"
    /// The root `CHANGELOG.md`, bundled at the top level.
    static let unreleasedResource = "CHANGELOG"

    let entries: [ChangelogEntry]

    /// Gregorian in UTC: a release date is a calendar day, the same
    /// wherever it is read.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// Reads the bundled files. Never throws: a file that can't be read or
    /// parsed is skipped, and a missing folder gives an empty catalog.
    static func bundled(in bundle: Bundle = .main) -> ChangelogCatalog {
        let releaseURLs = bundle.urls(forResourcesWithExtension: "md", subdirectory: subdirectory) ?? []
        let releases = releaseURLs.compactMap { url -> (name: String, markdown: String)? in
            guard let markdown = read(url) else { return nil }
            return (url.deletingPathExtension().lastPathComponent, markdown)
        }
        let changelog = bundle.url(forResource: unreleasedResource, withExtension: "md").flatMap(read)
        return parse(releases: releases, changelog: changelog)
    }

    /// The catalog from raw inputs (`bundled(in:)`, and tests). `releases`
    /// are file names without `.md` and their text; a release that fails
    /// ``release(name:markdown:)`` or repeats an earlier version is skipped.
    static func parse(releases: [(name: String, markdown: String)], changelog: String?) -> ChangelogCatalog {
        var seen: Set<ChangelogVersion> = []
        var shipped: [(version: ChangelogVersion, entry: ChangelogEntry)] = []
        for source in releases {
            guard let entry = release(name: source.name, markdown: source.markdown),
                case .release(let version, _) = entry.kind,
                seen.insert(version).inserted
            else { continue }
            shipped.append((version, entry))
        }
        shipped.sort { $0.version > $1.version }
        let upcoming = changelog.flatMap(unreleased(in:))
        return ChangelogCatalog(entries: (upcoming.map { [$0] } ?? []) + shipped.map(\.entry))
    }

    /// One release file: frontmatter `version` (the file's name too) and
    /// `date` (`YYYY-MM-DD`), then the release's Markdown. Nil when either
    /// field is missing or invalid, or the version is not the file's name.
    static func release(name: String, markdown: String) -> ChangelogEntry? {
        let frontmatter = MarkdownFrontmatter.parse(markdown)
        guard let versionText = frontmatter.version, versionText == name,
            let version = ChangelogVersion(versionText),
            let dateText = frontmatter.date, let date = day(dateText)
        else { return nil }
        return ChangelogEntry(
            kind: .release(version, date: date), body: strippingReferences(frontmatter.body).trimmed)
    }

    /// The body under `## [Unreleased]` up to the next `## ` heading or the
    /// end. Nil when there is no such section or it holds no list item:
    /// right after a release it is only empty `###` headings, if anything.
    static func unreleased(in changelog: String) -> ChangelogEntry? {
        let lines = TerminalTextSafety.normalizingNewlines(changelog)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## [Unreleased]" })
        else { return nil }
        let rest = lines[(heading + 1)...]
        let section = rest.prefix { !($0.hasPrefix("## ") || $0.trimmingCharacters(in: .whitespaces) == "##") }
        guard section.contains(where: isListItem) else { return nil }
        return ChangelogEntry(
            kind: .unreleased, body: strippingReferences(section.joined(separator: "\n")).trimmed)
    }

    /// `markdown` without its issue and PR references: each parenthetical
    /// of `#n`, `refs #n` or `PR #n` items joined by `,` or `;` (`(#105,
    /// refs #27)`, `(#320; PR #321)`), and the whitespace before it, even
    /// across a line break. They point into a private repository. The same
    /// rule as waycar.dev/changelog's.
    static func strippingReferences(_ markdown: String) -> String {
        markdown.replacing(
            #/\s*\((?:(?:refs|PR)\s+)?#\d+(?:\s*[,;]\s*(?:(?:refs|PR)\s+)?#\d+)*\)/#, with: "")
    }

    private static func isListItem(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let marker = trimmed.first, marker == "-" || marker == "*" || marker == "+" else { return false }
        return trimmed.dropFirst().first == " "
    }

    /// Midnight UTC of a `YYYY-MM-DD` calendar day; nil for any other text
    /// or a day the calendar lacks (`2026-02-30`).
    private static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.map(\.count) == [4, 2, 2],
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        let components = DateComponents(year: Int(parts[0]), month: Int(parts[1]), day: Int(parts[2]))
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == components.year, back.month == components.month, back.day == components.day else {
            return nil
        }
        return date
    }

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
