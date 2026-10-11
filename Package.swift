// swift-tools-version: 6.2
import PackageDescription

/// App extensions start in Foundation's NSExtensionMain.
let extensionEntry: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"]),
        .library(name: "OrgIndex", targets: ["OrgIndex"]),
        .library(name: "OrgWorkspace", targets: ["OrgWorkspace"]),
        .library(name: "OrgPresentation", targets: ["OrgPresentation"]),
        .library(name: "OrgEditorAppKit", targets: ["OrgEditorAppKit"]),
        .executable(name: "OrgstarSpike", targets: ["OrgstarSpike"]),
        .library(name: "OrgApp", targets: ["OrgApp"]),
        .library(name: "OrgHighlight", targets: ["OrgHighlight"]),
        .executable(name: "Orgstar", targets: ["Orgstar"]),
        .executable(name: "OrgstarMobile", targets: ["OrgstarMobile"]),
        .executable(name: "OrgstarQuickLook", targets: ["OrgstarQuickLook"]),
        .executable(name: "OrgstarSpotlight", targets: ["OrgstarSpotlight"]),
        .executable(name: "OrgstarShare", targets: ["OrgstarShare"]),
        .executable(name: "OrgstarWidgets", targets: ["OrgstarWidgets"]),
        .executable(name: "OrgstarWatch", targets: ["OrgstarWatch"]),
        .executable(name: "OrgstarWatchWidgets", targets: ["OrgstarWatchWidgets"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/mgriebling/SwiftMath", exact: "1.7.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-c", exact: "0.24.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-cpp", exact: "0.23.4"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-haskell", exact: "0.24.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", exact: "0.23.5"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-lua", exact: "0.5.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.25.0"),
        .package(url: "https://github.com/r-lib/tree-sitter-r", exact: "1.3.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.2"),
        .package(url: "https://github.com/6cdh/tree-sitter-scheme", exact: "0.24.7-1"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.2")
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .target(name: "OrgIndex", dependencies: ["OrgCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "OrgWorkspace", dependencies: ["OrgIndex"]),
        .target(name: "OrgPresentation", dependencies: ["OrgCore", .product(name: "SwiftMath", package: "SwiftMath")]),
        .target(name: "OrgEditorAppKit", dependencies: ["OrgDocument", "OrgPresentation"]),
        .target(name: "TreeSitterElisp", path: "Sources/TreeSitterElisp", sources: ["src/parser.c"], cSettings: [.headerSearchPath("src")]),
        .target(name: "TreeSitterClojure", path: "Sources/TreeSitterClojure", sources: ["src/parser.c"], cSettings: [.headerSearchPath("src")]),
        .target(
            name: "TreeSitterScanners", path: "Sources/TreeSitterScanners",
            sources: ["javascript/scanner.c", "lua/scanner.c", "python/scanner.c", "yaml/scanner.c"],
            cSettings: [.unsafeFlags(["-Wno-shorten-64-to-32"])]
        ),
        .target(
            name: "OrgHighlight",
            dependencies: [
                "OrgPresentation", "TreeSitterElisp", "TreeSitterClojure", "TreeSitterScanners",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterC", package: "tree-sitter-c"),
                .product(name: "TreeSitterCPP", package: "tree-sitter-cpp"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterHaskell", package: "tree-sitter-haskell"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterR", package: "tree-sitter-r"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterScheme", package: "tree-sitter-scheme"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml")
            ]
        ),
        .executableTarget(name: "OrgstarSpike", dependencies: ["OrgEditorAppKit"]),
        .target(name: "OrgApp", dependencies: ["OrgWorkspace", "OrgDocument", "OrgPresentation", "OrgWatchData"]),
        // What the phone and the watch send each other; Foundation only, so the watch builds it.
        .target(name: "OrgWatchData"),
        // The watch app and its complications, bundled by scripts/build-watch-app.sh.
        .executableTarget(name: "OrgstarWatch", dependencies: ["OrgWatchData"]),
        .executableTarget(name: "OrgstarWatchWidgets", dependencies: ["OrgWatchData"]),
        .executableTarget(name: "Orgstar", dependencies: ["OrgApp", "OrgEditorAppKit", "OrgHighlight", .product(name: "Sparkle", package: "Sparkle")]),
        // The iOS app, bundled by scripts/build-ios-app.sh.
        .executableTarget(name: "OrgstarMobile", dependencies: ["OrgApp", "OrgHighlight"]),
        // App extensions, bundled into orgstar.app by scripts/build-app.sh.
        .executableTarget(name: "OrgstarQuickLook", dependencies: ["OrgCore"], linkerSettings: extensionEntry),
        .executableTarget(name: "OrgstarSpotlight", dependencies: ["OrgCore"], linkerSettings: extensionEntry),
        // The iOS share extension, bundled into the iOS app by scripts/build-ios-app.sh.
        .executableTarget(name: "OrgstarShare", dependencies: ["OrgApp"], linkerSettings: extensionEntry),
        // The Mac's widget extension, bundled into the app by scripts/build-app.sh; the iOS one
        // is built from the same sources by ios/Orgstar.xcodeproj.
        .executableTarget(name: "OrgstarWidgets", dependencies: ["OrgApp"]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"], exclude: ["Conformance"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"]),
        .testTarget(name: "OrgWatchDataTests", dependencies: ["OrgWatchData"]),
        .testTarget(name: "OrgIndexTests", dependencies: ["OrgIndex"]),
        .testTarget(name: "OrgWorkspaceTests", dependencies: ["OrgWorkspace"]),
        .testTarget(name: "OrgPresentationTests", dependencies: ["OrgPresentation"]),
        .testTarget(name: "OrgEditorAppKitTests", dependencies: ["OrgEditorAppKit", "OrgApp"]),
        .testTarget(name: "OrgAppTests", dependencies: ["OrgApp", "OrgDocument"]),
        .testTarget(name: "OrgHighlightTests", dependencies: ["OrgHighlight", "OrgCore", "OrgPresentation"])
    ]
)
