// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterSql",
    products: [
        .library(name: "TreeSitterSql", targets: ["TreeSitterSql"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TreeSitterSql",
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
