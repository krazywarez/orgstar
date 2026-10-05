// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"]),
        .library(name: "OrgIndex", targets: ["OrgIndex"]),
        .library(name: "OrgWorkspace", targets: ["OrgWorkspace"]),
        .library(name: "OrgPresentation", targets: ["OrgPresentation"]),
        .library(name: "OrgEditorAppKit", targets: ["OrgEditorAppKit"]),
        .executable(name: "OrgstarSpike", targets: ["OrgstarSpike"]),
        .library(name: "OrgApp", targets: ["OrgApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .target(name: "OrgIndex", dependencies: ["OrgCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "OrgWorkspace", dependencies: ["OrgIndex"]),
        .target(name: "OrgPresentation", dependencies: ["OrgCore"]),
        .target(name: "OrgEditorAppKit", dependencies: ["OrgDocument", "OrgPresentation"]),
        .executableTarget(name: "OrgstarSpike", dependencies: ["OrgEditorAppKit"]),
        .target(name: "OrgApp", dependencies: ["OrgWorkspace", "OrgDocument", "OrgPresentation"]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"]),
        .testTarget(name: "OrgIndexTests", dependencies: ["OrgIndex"]),
        .testTarget(name: "OrgWorkspaceTests", dependencies: ["OrgWorkspace"]),
        .testTarget(name: "OrgPresentationTests", dependencies: ["OrgPresentation"]),
        .testTarget(name: "OrgEditorAppKitTests", dependencies: ["OrgEditorAppKit"]),
        .testTarget(name: "OrgAppTests", dependencies: ["OrgApp"])
    ]
)
