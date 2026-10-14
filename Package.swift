// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Screenshotter",
    platforms: [.macOS(.v14)],
    dependencies: [
        // ImageIO decodes WebP but can't encode it.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", exact: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Screenshotter",
            dependencies: [.product(name: "libwebp", package: "libwebp-Xcode")],
            path: "Sources/Screenshotter",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ScreenshotterTests", dependencies: ["Screenshotter"]),
    ]
)
