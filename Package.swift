// swift-tools-version: 6.2
// Day-one spike: can a plain Swift Package CLI (no app bundle, no entitlements) open a
// Foundation Models session on this Mac, get one answer, and write one receipt-shaped record?
import PackageDescription

let package = Package(
    name: "septdrift",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SeptdriftCore",
            dependencies: [.product(name: "Yams", package: "Yams")],
            path: "Sources/SeptdriftCore"
        ),
        .executableTarget(
            name: "septdrift",
            dependencies: [
                "SeptdriftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/septdrift"
        ),
        .testTarget(
            name: "SeptdriftCoreTests",
            dependencies: ["SeptdriftCore"],
            path: "Tests/SeptdriftCoreTests"
        )
    ]
)
