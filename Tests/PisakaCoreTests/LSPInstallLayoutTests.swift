import XCTest
@testable import PisakaCore

/// The layout is the one place that knows what the install tree looks like, and
/// three separate things depend on the answers being the same: the engine (which
/// creates and moves the directories), the registry entries (which name paths
/// inside them) and the de-provisioning instructions in `README.md` (which tell a
/// user to delete one). Pinning the composition here is what keeps those three
/// from drifting apart silently — a layout change that broke the registry would
/// otherwise surface as "the language server stopped starting".
final class LSPInstallLayoutTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Pisaka/LanguageServers")
    private var layout: LSPInstallLayout { LSPInstallLayout(base: base) }

    // MARK: - Composition

    func testTheTreeComposesAsDocumented() {
        XCTAssertEqual(layout.componentDirectory("node").path, base.path + "/node")
        XCTAssertEqual(layout.versionDirectory(componentID: "node", version: "24.19.0").path, base.path + "/node/24.19.0")
        XCTAssertEqual(layout.stagingRoot.path, base.path + "/.staging")
        XCTAssertEqual(
            layout.stagingDirectory(componentID: "node", version: "24.19.0", token: 7).path,
            base.path + "/.staging/node-24.19.0-7"
        )
    }

    func testAComponentResolvesToItsOwnVersionDirectory() {
        XCTAssertEqual(layout.versionDirectory(for: .node).path, base.path + "/node/24.19.0")
        XCTAssertEqual(
            layout.versionDirectory(for: .typescriptLanguageServer).path,
            base.path + "/typescript-language-server/5.3.0"
        )
        XCTAssertEqual(layout.versionDirectory(for: .pyright).path, base.path + "/pyright/1.1.411")
        XCTAssertEqual(
            layout.stagingDirectory(for: .pyright, token: 0).path,
            base.path + "/.staging/pyright-1.1.411-0"
        )
    }

    /// A multi-component subpath composes; the empty one answers the version
    /// directory *without* a trailing slash, which is what keeps path comparison
    /// (and `contains(_:)`) honest.
    func testASubpathComposesAndTheEmptyOneIsTheVersionDirectoryItself() {
        XCTAssertEqual(layout.file("bin/node", of: .node).path, base.path + "/node/24.19.0/bin/node")
        XCTAssertEqual(layout.file("", of: .node).path, base.path + "/node/24.19.0")
        XCTAssertEqual(layout.file("", of: .node).path, layout.versionDirectory(for: .node).path)
    }

    func testTheExecutableAndLicensePathsComeFromTheComponent() {
        XCTAssertEqual(layout.executable(of: .node)?.path, base.path + "/node/24.19.0/bin/node")
        XCTAssertEqual(
            layout.executable(of: .pyright)?.path,
            base.path + "/pyright/1.1.411/node_modules/pyright/dist/pyright-langserver.js"
        )
        XCTAssertEqual(layout.licenseFiles(of: .node).map(\.path), [base.path + "/node/24.19.0/LICENSE"])
        // In manifest order, and one entry per *notice* rather than per package:
        // `typescript` carries a separate third-party notice beside its license.
        XCTAssertEqual(layout.licenseFiles(of: .typescriptLanguageServer).map(\.path), [
            base.path + "/typescript-language-server/5.3.0/node_modules/typescript-language-server/LICENSE",
            base.path + "/typescript-language-server/5.3.0/node_modules/typescript/LICENSE.txt",
            base.path + "/typescript-language-server/5.3.0/node_modules/typescript/ThirdPartyNoticeText.txt",
        ])
        XCTAssertEqual(layout.licenseFiles(of: .pyright).map(\.path), [
            base.path + "/pyright/1.1.411/node_modules/pyright/LICENSE.txt",
            base.path + "/pyright/1.1.411/node_modules/pyright/dist/typeshed-fallback/LICENSE",
            base.path + "/pyright/1.1.411/node_modules/fsevents/LICENSE",
        ])

        // A component with nothing to run answers nothing rather than a path into
        // a file that does not exist.
        let library = LSPComponent(id: "lib", version: "1", licenseSPDX: "MIT", licenseFileSubpaths: [], artifacts: [])
        XCTAssertNil(layout.executable(of: library))
        XCTAssertEqual(layout.licenseFiles(of: library), [])
    }

    // MARK: - Staging mirrors the installed tree

    /// D13's whole trick: an artifact's position relative to the root it unpacks
    /// into is the same in staging as it is once installed, so the final `move` of
    /// one directory finishes the job with nothing left to relocate.
    func testAnArtifactSitsAtTheSameRelativePositionInStagingAndOnceInstalled() {
        let component = LSPComponent.typescriptLanguageServer
        let staging = layout.stagingDirectory(for: component, token: 3)
        let installed = layout.versionDirectory(for: component)

        for artifact in component.artifacts {
            let inStaging = layout.destination(of: artifact, unpackingInto: staging).path
            let onceInstalled = layout.destination(of: artifact, unpackingInto: installed).path
            XCTAssertEqual(
                inStaging.replacingOccurrences(of: staging.path, with: installed.path), onceInstalled,
                "\(artifact.destinationSubpath) does not survive the rename unchanged"
            )
        }

        XCTAssertEqual(
            layout.destination(of: component.artifacts[1], unpackingInto: staging).path,
            base.path + "/.staging/typescript-language-server-5.3.0-3/node_modules/typescript"
        )
        // Node's empty destination puts the tarball's contents at the root of
        // whatever it is unpacking into.
        XCTAssertEqual(
            layout.destination(of: LSPComponent.node.artifacts[0], unpackingInto: staging).path,
            staging.path
        )
    }

    /// Two attempts at the same component and version must not share a scratch
    /// tree: a retry that adopted the previous attempt's half-written directory
    /// would install exactly the corruption the staging discipline exists to
    /// prevent.
    func testEveryAttemptGetsItsOwnStagingDirectory() {
        let first = layout.stagingDirectory(componentID: "node", version: "24.19.0", token: 1)
        let second = layout.stagingDirectory(componentID: "node", version: "24.19.0", token: 2)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, layout.stagingDirectory(componentID: "node", version: "24.19.0", token: 1))

        // Different components and versions are distinct even at the same token.
        XCTAssertNotEqual(first, layout.stagingDirectory(componentID: "node", version: "24.19.1", token: 1))
        XCTAssertNotEqual(first, layout.stagingDirectory(componentID: "pyright", version: "24.19.0", token: 1))

        // And staging is inside the base, so the final move is a rename on one
        // volume rather than a cross-device copy.
        XCTAssertTrue(layout.contains(first))
        XCTAssertEqual(first.deletingLastPathComponent().path, layout.stagingRoot.path)
    }

    // MARK: - Containment

    func testEverythingTheLayoutAnswersIsInsideTheBase() {
        for component in LSPProvisioningManifest.standard.components {
            XCTAssertTrue(layout.contains(layout.componentDirectory(component.id)))
            XCTAssertTrue(layout.contains(layout.versionDirectory(for: component)))
            XCTAssertTrue(layout.contains(layout.stagingDirectory(for: component, token: 0)))
            XCTAssertTrue(layout.licenseFiles(of: component).allSatisfy(layout.contains))
            if let executable = layout.executable(of: component) {
                XCTAssertTrue(layout.contains(executable))
            }
        }
        XCTAssertTrue(layout.contains(layout.stagingRoot))
        XCTAssertTrue(layout.contains(base), "the root contains itself; the engine may sweep it")
    }

    /// The negative half — the assertion is only worth something if it can fail.
    /// A sibling whose path is a *string* prefix of the base is the case a naive
    /// `hasPrefix` gets wrong, and it is exactly the case that would let a delete
    /// escape the install root.
    func testAPathOutsideTheBaseIsNotContained() {
        XCTAssertFalse(layout.contains(base.deletingLastPathComponent()))
        XCTAssertFalse(layout.contains(URL(fileURLWithPath: base.path + "-backup")))
        XCTAssertFalse(layout.contains(URL(fileURLWithPath: "/etc/passwd")))
        XCTAssertFalse(layout.contains(base.appendingPathComponent("../elsewhere")))
    }

    func testTheBaseIsStandardisedSoTwoSpellingsOfOneRootAgree() {
        let noisy = LSPInstallLayout(base: URL(fileURLWithPath: "/tmp/servers/./node/.."))
        XCTAssertEqual(noisy.base.path, "/tmp/servers")
        XCTAssertEqual(noisy, LSPInstallLayout(base: URL(fileURLWithPath: "/tmp/servers")))
        XCTAssertTrue(noisy.contains(noisy.versionDirectory(componentID: "node", version: "1")))
    }
}
