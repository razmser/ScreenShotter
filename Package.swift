// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Screenshotter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Screenshotter",
            path: "Sources/Screenshotter",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ScreenshotterTests", dependencies: ["Screenshotter"]),
    ]
)
