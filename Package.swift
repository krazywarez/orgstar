// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"])
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"])
    ]
)
