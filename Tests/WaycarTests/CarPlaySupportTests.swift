import Foundation
import Testing
import UIKit

@testable import Waycar

/// An iPad never connects to CarPlay: only an iPhone on iOS 26.4 or later
/// shows CarPlay UI.
@Suite("CarPlay support")
struct CarPlaySupportTests {
    /// Idiom, iOS major and minor version, and whether CarPlay is available.
    static let matrix: [(UIUserInterfaceIdiom, Int, Int, Bool)] = [
        (.phone, 18, 6, false),
        (.phone, 26, 3, false),
        (.phone, 26, 4, true),
        (.phone, 26, 6, true),
        (.phone, 27, 0, true),
        (.pad, 26, 3, false),
        (.pad, 26, 4, false),
        (.pad, 26, 6, false),
        (.pad, 27, 0, false),
        (.mac, 27, 0, false),
        (.vision, 27, 0, false),
    ]

    @Test(arguments: matrix)
    func onlyAnIPhoneOnIOS264OrLater(
        idiom: UIUserInterfaceIdiom, major: Int, minor: Int, available: Bool
    ) {
        let system = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        #expect(CarPlaySupport.isAvailable(idiom: idiom, system: system) == available)
    }

    /// The live check reads this device: the iPad runs see no CarPlay.
    @Test @MainActor func theLiveCheckFollowsThisDevice() {
        let newEnough: Bool = if #available(iOS 26.4, *) { true } else { false }
        #expect(CarPlaySupport.isAvailable == (UIDevice.current.userInterfaceIdiom == .phone && newEnough))
    }
}
