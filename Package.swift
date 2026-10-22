// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Eddie",
    platforms: [.macOS(.v15)],
    products: [
        // The whole app. The Edwell app target in App/ (Xcode) and the Eddie executable below both run it.
        .library(name: "EddieKit", targets: ["EddieKit"]),
    ],
    dependencies: [
        // The IAMJARL design system: colours, spacing, radius and type for every IAMJARL app.
        .package(url: "https://github.com/jarllyng/iamjarl-design.git", from: "1.35.0"),
    ],
    targets: [
        .target(
            name: "EddieKit",
            dependencies: [.product(name: "IAMJARLDesignTokens", package: "iamjarl-design")],
            path: "Sources/EddieKit"
        ),
        // `swift build` makes .build/debug/Eddie, for the self test and quick runs without Xcode.
        .executableTarget(
            name: "Eddie",
            dependencies: ["EddieKit"],
            path: "Sources/Eddie"
        ),
    ],
    swiftLanguageModes: [.v5]
)
