import Foundation
import Testing
import UIKit

@testable import Waycar

@MainActor
private final class FakeIconHost: AlternateIconHost {
    struct Refused: Error {}

    var supportsAlternateIcons = true
    var alternateIconName: String?
    var refuse = false
    private(set) var requests: [String?] = []

    init(alternateIconName: String? = nil) {
        self.alternateIconName = alternateIconName
    }

    func setAlternateIconName(_ alternateIconName: String?) async throws {
        requests.append(alternateIconName)
        if refuse { throw Refused() }
        self.alternateIconName = alternateIconName
    }
}

@MainActor
@Suite("App icon settings")
struct AppIconSettingsTests {
    @Test func readsTheIconIOSReports() {
        #expect(AppIconSettings(host: FakeIconHost()).selection == .primary)
        #expect(
            AppIconSettings(host: FakeIconHost(alternateIconName: "AppIconPromptAmber")).selection
                == .promptAmber)
    }

    /// An icon a newer build shipped must not leave an older one pointing at
    /// nothing: it reads as the primary icon.
    @Test func unknownIconNameReadsAsThePrimary() {
        #expect(AppIconSettings(host: FakeIconHost(alternateIconName: "AppIconFromTheFuture")).selection == .primary)
    }

    @Test func selectingAsksIOSForTheAlternateName() async {
        let host = FakeIconHost()
        let settings = AppIconSettings(host: host)

        await settings.select(.cabooseTomato)
        await settings.select(.primary)

        #expect(host.requests == ["AppIconCabooseTomato", nil])
        #expect(settings.selection == .primary)
        #expect(settings.lastError == nil)
    }

    @Test func reselectingTheCurrentIconDoesNothing() async {
        let host = FakeIconHost(alternateIconName: "AppIconPromptMono")
        let settings = AppIconSettings(host: host)

        await settings.select(.promptMono)

        #expect(host.requests.isEmpty)
    }

    @Test func refusalKeepsTheCurrentIconAndReportsIt() async {
        let host = FakeIconHost(alternateIconName: "AppIconCabooseMono")
        host.refuse = true
        let settings = AppIconSettings(host: host)

        await settings.select(.promptCoral)

        #expect(settings.selection == .cabooseMono)
        #expect(settings.lastError != nil)
    }

    @Test func everyMarkOffersSeveralPalettes() {
        for mark in AppIconMark.allCases {
            let options = AppIconOption.options(for: mark)
            #expect(options.count > 1)
            #expect(Set(options.map(\.title)).count == options.count, "duplicate title under \(mark)")
        }
        #expect(AppIconOption.primary.alternateIconName == nil)
        #expect(AppIconOption.primary.mark == .caboose)
    }

    /// The enum, the build setting and the generated `.icon` bundles must
    /// agree, or `setAlternateIconName` fails at runtime. The compiled
    /// Info.plist is where the build setting lands. Read raw: `infoDictionary`
    /// folds `~ipad` keys away on iPhone.
    @Test func everyAlternateIconShipsInTheBundle() throws {
        let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let icons = try #require(plist[key] as? [String: Any], "\(key)")
            let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any], "\(key)")
            let expected = Set(AppIconOption.allCases.compactMap(\.alternateIconName))
            #expect(Set(alternates.keys) == expected, "\(key)")
        }
    }

    @Test func notificationNoteLinksToTheAppleForumThread() {
        #expect(AppIconPickerView.notificationBugURL?.host() == "developer.apple.com")
    }

    @Test func everyIconHasAPreview() {
        for option in AppIconOption.allCases {
            #expect(UIImage(named: option.previewImageName) != nil, "\(option.previewImageName)")
        }
    }
}
