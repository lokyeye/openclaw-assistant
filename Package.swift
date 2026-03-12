// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenClawAssistant",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "OpenClawAssistant",
            targets: ["OpenClawAssistant"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "OpenClawAssistant",
            path: "Sources/OpenClawAssistant"
        ),
    ]
)
