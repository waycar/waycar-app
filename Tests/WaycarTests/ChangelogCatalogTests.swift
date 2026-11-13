import Foundation
import Testing

@testable import Waycar

/// The changelog the app bundles for Settings › About › Changelog: one file
/// per release from `apps/web/src/content/changelog` plus `CHANGELOG.md`'s
/// `[Unreleased]`, newest first, issue and PR references removed.
@Suite("Changelog catalog")
struct ChangelogCatalogTests {
    private static func release(_ version: String, date: String = "2026-10-04", body: String = "- **A**: b") -> (
        name: String, markdown: String
    ) {
        (version, "---\nversion: \(version)\ndate: \(date)\n---\n\n### Added\n\n\(body)\n")
    }

    // MARK: The bundled files

    @Test func bundleCarriesEveryReleaseFile() throws {
        let files = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: ChangelogCatalog.subdirectory) ?? []
        #expect(!files.isEmpty)
        let releases = ChangelogCatalog.bundled().entries.filter { $0.kind != .unreleased }
        #expect(releases.count == files.count)
        #expect(Set(releases.map(\.id)) == Set(files.map { $0.deletingPathExtension().lastPathComponent }))
        #expect(Bundle.main.url(forResource: ChangelogCatalog.unreleasedResource, withExtension: "md") != nil)
    }

    @Test func bundledChangelogLeadsWithUnreleasedThenNewestVersion() {
        let entries = ChangelogCatalog.bundled().entries
        // Unreleased, when shown, is the first entry and the only one.
        #expect(entries.dropFirst().allSatisfy { $0.kind != .unreleased })
        #expect(Set(entries.map(\.id)).count == entries.count)

        let versions = entries.compactMap { entry -> ChangelogVersion? in
            guard case .release(let version, _) = entry.kind else { return nil }
            return version
        }
        #expect(versions == versions.sorted(by: >))
    }

    @Test func documentRowsHaveUniqueIDsAndOneHeadingPerEntry() {
        let catalog = ChangelogCatalog.bundled()
        let document = ChangelogDocument(catalog)
        #expect(Set(document.rows.map(\.id)).count == document.rows.count)
        let headings = document.rows.compactMap { row -> String? in
            guard case .heading(let entry, _) = row else { return nil }
            return entry.id
        }
        #expect(headings == catalog.entries.map(\.id))
        guard case .heading(_, let isFirst)? = document.rows.first else {
            Issue.record("the document doesn't start with a heading")
            return
        }
        #expect(isFirst)
    }

    // MARK: Ordering

    @Test func releasesSortByNumericVersionNewestFirst() {
        let catalog = ChangelogCatalog.parse(
            releases: [
                Self.release("1.9.0"), Self.release("1.10.0"), Self.release("0.2.0"),
                Self.release("1.0.10"), Self.release("1.0.9"), Self.release("10.0.0"),
            ],
            changelog: nil)
        #expect(catalog.entries.map(\.id) == ["10.0.0", "1.10.0", "1.9.0", "1.0.10", "1.0.9", "0.2.0"])
    }

    @Test func unreleasedComesFirst() {
        let catalog = ChangelogCatalog.parse(
            releases: [Self.release("1.0.0"), Self.release("2.0.0")],
            changelog: "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- **New**: thing\n")
        #expect(catalog.entries.map(\.id) == ["unreleased", "2.0.0", "1.0.0"])
        #expect(catalog.entries.first?.title == "Unreleased")
        #expect(catalog.entries.first?.subtitle() == "Coming in the next update.")
    }

    @Test func versionsCompareNumerically() throws {
        let nine = try #require(ChangelogVersion("1.9.0"))
        let ten = try #require(ChangelogVersion("1.10.0"))
        #expect(nine < ten)
        #expect(ten.description == "1.10.0")
        for invalid in ["1.2", "1.2.3.4", "v1.2.3", "1.02.3", "1..3", "1.2.x", "", "1.2.3-beta", "１.2.3"] {
            #expect(ChangelogVersion(invalid) == nil, "\(invalid)")
        }
        #expect(ChangelogVersion("0.0.0") != nil)
    }

    @Test func releaseTitleAndLongDate() throws {
        let entry = try #require(
            ChangelogCatalog.release(name: "1.1.3", markdown: Self.release("1.1.3", date: "2026-10-04").markdown))
        #expect(entry.title == "Version 1.1.3")
        #expect(entry.subtitle(locale: Locale(identifier: "en_US")) == "October 4, 2026")
        #expect(entry.body == "### Added\n\n- **A**: b")
    }

    // MARK: Unreleased

    @Test func unreleasedRunsToTheNextSectionOrTheEnd() throws {
        let present = try #require(
            ChangelogCatalog.unreleased(
                in: """
                    # Changelog

                    Intro with a [link](https://keepachangelog.com/en/1.1.0/).

                    ## [Unreleased]

                    ### Added

                    - **First**: one (#1)
                      wrapped.

                    ### Fixed

                    * **Second**: two

                    ## [1.0.0] - 2026-01-01

                    - **Old**: not this
                    """))
        #expect(present.kind == .unreleased)
        #expect(present.body == "### Added\n\n- **First**: one\n  wrapped.\n\n### Fixed\n\n* **Second**: two")

        let atEnd = try #require(ChangelogCatalog.unreleased(in: "## [Unreleased]\r\n\r\n- **Only**: item\r\n"))
        #expect(atEnd.body == "- **Only**: item")
    }

    @Test func unreleasedWithoutAnyItemIsHidden() {
        // Right after `make publish`: the file ends at the heading line, its
        // header list included.
        #expect(
            ChangelogCatalog.unreleased(
                in: "# Changelog\n\nAll notable changes.\n\n- Not a release item\n\n## [Unreleased]\n") == nil)
        #expect(ChangelogCatalog.unreleased(in: "# Changelog\n\n## [Unreleased]\n") == nil)
        #expect(ChangelogCatalog.unreleased(in: "# Changelog\n\n## [Unreleased]") == nil)
        #expect(ChangelogCatalog.unreleased(in: "# Changelog\n\n## [Unreleased]\n\n## [1.0.0]\n\n- **Old**: x\n") == nil)
        // Headings and prose but no bullet.
        #expect(ChangelogCatalog.unreleased(in: "## [Unreleased]\n\n### Added\n\nNothing yet.\n-not a bullet\n") == nil)
        // No section at all.
        #expect(ChangelogCatalog.unreleased(in: "# Changelog\n\n- **Stray**: item\n") == nil)
        #expect(ChangelogCatalog.parse(releases: [], changelog: "## [Unreleased]\n").entries.isEmpty)
    }

    // MARK: References

    @Test(arguments: [
        ("- **A**: fix. (#161)", "- **A**: fix."),
        ("- **A**: fix (#95, refs #90).", "- **A**: fix."),
        ("- **A**: fix (#105, refs #27)", "- **A**: fix"),
        ("- **A**: fix (PR #302)", "- **A**: fix"),
        ("- **A**: fix (#320; PR #321)", "- **A**: fix"),
        ("- **A**: fix (#151, #164; PR #174)", "- **A**: fix"),
        ("- **A**: fix (#101, #102, #103, #104; PR #105)", "- **A**: fix"),
        ("- **A**: the end of the line\n  (#161)\n- **B**: next", "- **A**: the end of the line\n- **B**: next"),
        ("- **A**: wraps (#105, refs\n  #27) on.", "- **A**: wraps on."),
        ("Blocked: approve merge of PR #512 (and more)", "Blocked: approve merge of PR #512 (and more)"),
        ("Keep (see Settings) and (#x) and (refs) as written", "Keep (see Settings) and (#x) and (refs) as written"),
    ])
    func referencesAreStripped(source: String, expected: String) {
        #expect(ChangelogCatalog.strippingReferences(source) == expected)
    }

    @Test func releaseAndUnreleasedBodiesAreStripped() throws {
        let entry = try #require(
            ChangelogCatalog.release(
                name: "1.0.0", markdown: Self.release("1.0.0", body: "- **A**: b (#1, refs\n  #2)").markdown))
        #expect(entry.body == "### Added\n\n- **A**: b")
        let unreleased = try #require(ChangelogCatalog.unreleased(in: "## [Unreleased]\n\n- **A**: b (PR #3)\n"))
        #expect(unreleased.body == "- **A**: b")
    }

    // MARK: Malformed files

    @Test func malformedReleasesAreSkippedNotFatal() {
        let catalog = ChangelogCatalog.parse(
            releases: [
                Self.release("1.0.0"),
                ("1.1.0", "### Added\n\n- **No frontmatter**: x\n"),
                ("1.2.0", "---\ndate: 2026-10-04\n---\n\n- **No version**: x\n"),
                ("1.3.0", "---\nversion: 1.3.0\n---\n\n- **No date**: x\n"),
                ("1.4", "---\nversion: 1.4\ndate: 2026-10-04\n---\n\n- **Short version**: x\n"),
                ("1.5.0", "---\nversion: 1.6.0\ndate: 2026-10-04\n---\n\n- **Name mismatch**: x\n"),
                Self.release("1.7.0", date: "2026-02-30"),
                Self.release("1.8.0", date: "2026-1-5"),
                Self.release("1.9.0", date: "October 4, 2026"),
                ("2.0.0", "---\nversion: \"2.0.0\"\ndate: '2026-10-05'\n---\n\n- **Quoted**: fine\n"),
                Self.release("1.0.0", date: "2026-11-01"),
            ],
            changelog: nil)
        #expect(catalog.entries.map(\.id) == ["2.0.0", "1.0.0"])
        // The first 1.0.0 wins over the duplicate.
        guard case .release(_, let date)? = catalog.entries.last?.kind else {
            Issue.record("no 1.0.0")
            return
        }
        let day = ChangelogCatalog.calendar.dateComponents([.month, .day], from: date)
        #expect(day.month == 10 && day.day == 4)
    }

    @Test func missingBundleGivesAnEmptyCatalog() throws {
        let empty = try #require(Bundle(path: NSTemporaryDirectory()))
        #expect(ChangelogCatalog.bundled(in: empty).entries.isEmpty)
    }
}
