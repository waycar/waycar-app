// swift-tools-version: 6.0
import PackageDescription

// Vendored libghostty-spm 1.6.20260909 (7e45d27) with Waycar's patches; see
// PROVENANCE.md. Only the products the app links are kept. The native core is
// Waycar's own build of the same Ghostty commit without GNU gettext
// (Scripts/build-libghostty.sh, ADR 0025), published at otreva/ghosttykit and
// checksum-verified by SwiftPM.
let package = Package(
    name: "GhosttyKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
        .macCatalyst(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "GhosttyTerminal", targets: ["GhosttyTerminal"]),
        .library(name: "GhosttyTheme", targets: ["GhosttyTheme"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/MSDisplayLink.git", exact: "2.2.0"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            dependencies: ["libghostty"],
            path: "Sources/GhosttyKit",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit", "MSDisplayLink"],
            path: "Sources/GhosttyTerminal",
            resources: [
                .copy("Resources/Ghostty"),
                .copy("Resources/terminfo"),
            ]
        ),
        .target(
            name: "GhosttyTheme",
            dependencies: ["GhosttyTerminal"],
            path: "Sources/GhosttyTheme",
            exclude: ["LICENSE"]
        ),
        .binaryTarget(
            name: "libghostty",
            url: "https://github.com/otreva/ghosttykit/releases/download/1.6.20260909-82938b6-nointl.1/GhosttyKit.xcframework.zip",
            checksum: "d64018c8fad48bf84a32622c653d33ef0d40ed154e2a760304924497b79c7de9"
        ),
    ]
)
