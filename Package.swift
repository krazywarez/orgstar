// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"]),
        .library(name: "OrgIndex", targets: ["OrgIndex"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .target(name: "OrgIndex", dependencies: ["OrgCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"]),
        .testTarget(name: "OrgIndexTests", dependencies: ["OrgIndex"])
    ]
)
