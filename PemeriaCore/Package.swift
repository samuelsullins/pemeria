// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PemeriaCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PemeriaCore", targets: ["PemeriaCore"]),
    ],
    targets: [
        .target(name: "PemeriaCore"),
        .testTarget(name: "PemeriaCoreTests", dependencies: ["PemeriaCore"]),
    ]
)
