// swift-tools-version:5.3
import PackageDescription

// Vendored copy of pnx/tree-sitter-dotenv — see VENDORED.md for the upstream
// tag/SHA, what is copied verbatim, and the one deliberate change.
//
// The reason this grammar is vendored rather than consumed as a remote package
// (which is how every other grammar here except gitignore is consumed): the
// upstream manifest's `sources:` lists only `src/parser.c`, while the grammar
// declares an external scanner (`externals: [$._end_of_assignment]`) whose five
// `tree_sitter_dotenv_external_scanner_*` functions live in `src/scanner.c`. The
// package therefore compiles but fails to *link* into an app — the symbols are
// referenced by `parser.c` and defined nowhere. The `sources:` list below adds
// `src/scanner.c`; that is the only substantive difference from upstream's
// manifest, and it must survive every update.
//
// The rest of the layout mirrors the grammar packages this project already
// consumes (`tree-sitter-json` is the reference): `path: "."` with an explicit
// `sources:` list, the queries directory copied as a resource, and the Swift
// binding header exposed via `publicHeadersPath`. Neon's
// `LanguageConfiguration(name:)` derives the resource-bundle name from the
// package/target name (`TreeSitterDotenv_TreeSitterDotenv.bundle`), which is how
// it finds `queries/highlights.scm` at runtime — so neither the package name nor
// the target name may be changed casually.
//
// Upstream's test target and its `SwiftTreeSitter` dependency are dropped: this
// package is consumed by the app target alone and must stay as inert as the
// remote grammar packages.
let package = Package(
    name: "TreeSitterDotenv",
    products: [
        .library(name: "TreeSitterDotenv", targets: ["TreeSitterDotenv"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TreeSitterDotenv",
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
