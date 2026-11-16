// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "afm-server",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
    ],
    targets: [
        .executableTarget(
            name: "afm-server",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")]
        ),
    ]
)
