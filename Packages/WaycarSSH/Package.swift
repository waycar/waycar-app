// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WaycarSSH",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "WaycarSSH", targets: ["WaycarSSH"]),
    ],
    targets: [
        .binaryTarget(
            name: "COpenSSL",
            path: "Artifacts/COpenSSL.xcframework"
        ),
        .binaryTarget(
            name: "CLibSSH2",
            path: "Artifacts/CLibSSH2.xcframework"
        ),
        .target(
            name: "CWaycarSSHSupport",
            dependencies: ["CLibSSH2"]
        ),
        .target(
            name: "WaycarSSH",
            dependencies: ["CLibSSH2", "COpenSSL", "CWaycarSSHSupport"]
        ),
        .testTarget(
            name: "WaycarSSHTests",
            dependencies: ["WaycarSSH"]
        ),
    ]
)
