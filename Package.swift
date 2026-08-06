// swift-tools-version:5.9
import PackageDescription

// The Pisaka *app* (the `Pisaka` executable, AppKit/SwiftUI/UIKit views, the
// syntax-highlighting and terminal dependencies, and — for iOS — libgit2) is
// built by the XcodeGen-generated Xcode project (`project.yml`), which targets
// both macOS 13 and iOS 17. `swift run Pisaka` is gone.
//
// This SwiftPM manifest now builds *only* the platform-agnostic `PisakaCore`
// library and its test suite, so `swift test` stays the fast, dependency-free
// gate for the domain logic (compiled for the host, and — per the audit in
// Phase 0 — source-compatible with iOS). All external dependencies
// (Neon/SwiftTreeSitter/Rearrange + tree-sitter grammars on every platform,
// SwiftTerm on macOS only) live in `project.yml` — the remote ones with their
// exact version/revision pins, and two tree-sitter grammars as local `path:`
// dependencies on the self-contained packages under `Vendor/`, which carry no
// `Package.resolved` pin because their directory contents *are* the pin.
// `PisakaCore` and the test target stay dependency-free — including of
// `Vendor/`, which this manifest deliberately does not reference.
let package = Package(
    name: "Pisaka",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        // Exposed as a library product so the XcodeGen-generated app target can
        // consume `PisakaCore` from this local package (a bare target is only
        // visible within its own package).
        .library(name: "PisakaCore", targets: ["PisakaCore"])
    ],
    targets: [
        .target(
            name: "PisakaCore"
        ),
        .testTarget(
            name: "PisakaCoreTests",
            dependencies: ["PisakaCore"]
        )
    ]
)
