// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HermesMini",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/LaunchDarkly/swift-eventsource.git", from: "3.3.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "HermesMini",
            dependencies: [
                .product(name: "LDSwiftEventSource", package: "swift-eventsource"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/HermesMini"
        )
    ]
)
