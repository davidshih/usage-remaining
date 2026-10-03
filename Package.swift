// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UsageWidget",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "UsageWidget", targets: ["UsageWidget"]),
    ],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "UsageWidget", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
