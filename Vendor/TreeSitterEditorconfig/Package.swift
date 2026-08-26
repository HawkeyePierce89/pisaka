// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterEditorconfig",
    products: [
        .library(name: "TreeSitterEditorconfig", targets: ["TreeSitterEditorconfig"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TreeSitterEditorconfig",
            dependencies: [],
            path: ".",
            sources: [
                "src/parser.c",
                "src/scanner.c",
            ],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
    ],
    cLanguageStandard: .c11
)
