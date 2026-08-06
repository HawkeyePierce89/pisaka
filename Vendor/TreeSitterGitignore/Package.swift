// swift-tools-version:5.3
import PackageDescription

// Vendored copy of shunsambongi/tree-sitter-gitignore — see VENDORED.md for the
// upstream SHA, what is copied verbatim, and what is written in this repo.
//
// The layout deliberately mirrors the upstream grammar packages this project
// already consumes (`tree-sitter-json` is the reference): `path: "."` with an
// explicit `sources:` list, the queries directory copied as a resource, and the
// Swift binding header exposed via `publicHeadersPath`. Neon's
// `LanguageConfiguration(name:)` derives the resource-bundle name from the
// package/target name (`TreeSitterGitignore_TreeSitterGitignore.bundle`), which
// is how it finds `queries/highlights.scm` at runtime — so neither the package
// name nor the target name may be changed casually.
//
// Upstream ships no `src/scanner.c`, so `sources:` lists only the parser.
// No test target and no external dependencies: this package is consumed by the
// app target alone and must stay as inert as the remote grammar packages.
let package = Package(
    name: "TreeSitterGitignore",
    products: [
        .library(name: "TreeSitterGitignore", targets: ["TreeSitterGitignore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TreeSitterGitignore",
            dependencies: [],
            path: ".",
            sources: [
                "src/parser.c",
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
