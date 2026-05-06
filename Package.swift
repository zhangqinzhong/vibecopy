// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VibeCopy",
    platforms: [
        .macOS("26.0")
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
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
