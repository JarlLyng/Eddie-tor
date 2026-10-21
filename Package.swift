// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Eddie",
    platforms: [.macOS(.v15)],
    dependencies: [
        // The IAMJARL design system: colours, spacing, radius and type for every IAMJARL app.
        .package(url: "https://github.com/jarllyng/iamjarl-design.git", from: "1.35.0"),
    ],
    targets: [
        .executableTarget(
            name: "Eddie",
            dependencies: [.product(name: "IAMJARLDesignTokens", package: "iamjarl-design")],
            path: "Sources/Eddie"
        )
    ],
    swiftLanguageModes: [.v5]
)
