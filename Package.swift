// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VibeCopy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VibeCopy", targets: ["VibeCopyApp"])
    ],
    targets: [
        .executableTarget(
            name: "VibeCopyApp",
            path: "Sources/VibeCopyApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("SwiftUI")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
