// swift-tools-version:5.9
// All scanning logic lives in this package so it can be unit-tested with
// `swift test` (no simulator needed). The iOS app (JobScan) only adds the UI.
import PackageDescription

let package = Package(
    name: "JobScanCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JobScanCore", targets: ["JobScanCore"]),
    ],
    targets: [
        .target(name: "JobScanCore"),
        .testTarget(name: "JobScanCoreTests", dependencies: ["JobScanCore"]),
    ]
)
