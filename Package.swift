// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"])
    ],
    targets: [
        .target(name: "OrgCore"),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"])
    ]
)
