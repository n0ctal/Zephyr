// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zephyr",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "Zephyr",
            path: "Sources/MacBookControl",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
