// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Eddie",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Eddie", path: "Sources/Eddie")
    ],
    swiftLanguageModes: [.v5]
)
