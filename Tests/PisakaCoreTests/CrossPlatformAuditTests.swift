import XCTest
import CoreGraphics
@testable import PisakaCore

/// Defensive audit that `PisakaCore`'s public constructors and enums are pure,
/// platform-independent Foundation logic — they must produce identical values on
/// macOS and iOS (Phase 0 of the iOS port). Core carries no `#if os(...)`
/// branches, so these assertions are stable everywhere; the test exists to catch
/// any future macOS-only API or platform-conditional drift slipping into Core
/// (which would either fail to compile for iOS or diverge here).
final class CrossPlatformAuditTests: XCTestCase {
    /// Raw values of the persisted preference enums are the stable on-disk form,
    /// so they must not vary by platform.
    func testPreferenceEnumRawValuesAreStable() {
        XCTAssertEqual(TabOrientation.vertical.rawValue, "vertical")
        XCTAssertEqual(TabOrientation.horizontal.rawValue, "horizontal")
        XCTAssertEqual(ThemePreference.system.rawValue, "system")
        XCTAssertEqual(ThemePreference.light.rawValue, "light")
        XCTAssertEqual(ThemePreference.dark.rawValue, "dark")
        XCTAssertEqual(TabOrientation.allCases, [.vertical, .horizontal])
        XCTAssertEqual(ThemePreference.allCases, [.system, .light, .dark])
    }

    /// `SyntaxLanguage`'s extension/file-name resolution is a pure map; it must
    /// resolve identically on every platform.
    func testSyntaxLanguageResolutionIsStable() {
        XCTAssertEqual(SyntaxLanguage(fileExtension: "swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(fileExtension: "TS"), .typescript)
        XCTAssertEqual(SyntaxLanguage(forFileName: "main.py"), .python)
        XCTAssertNil(SyntaxLanguage(fileExtension: "unknownext"))
    }

    /// `FileIcon` resolution (directory/special-name/extension/fallback) and its
    /// semantic, color-free `FileIconColor` must be platform-independent.
    func testFileIconResolutionIsStable() {
        let dir = DirectoryEntry(url: URL(fileURLWithPath: "/tmp/src"), isDirectory: true)
        XCTAssertEqual(FileIcon(for: dir).color, .accent)

        let unknown = DirectoryEntry(url: URL(fileURLWithPath: "/tmp/file.zzz"), isDirectory: false)
        XCTAssertEqual(FileIcon(for: unknown).color, .gray)

        // A special-cased file name resolves to something other than the unknown
        // fallback, so the special-name table is actually exercised (a regression
        // dropping `Package.swift` from it would collapse to the `.gray` doc icon).
        let pkg = DirectoryEntry(url: URL(fileURLWithPath: "/tmp/Package.swift"), isDirectory: false)
        XCTAssertNotEqual(FileIcon(for: pkg).symbolName, FileIcon(for: unknown).symbolName)
        XCTAssertNotEqual(FileIcon(for: pkg).color, FileIcon(for: unknown).color)
    }

    /// `MinimapGeometry` is the one Core type backed by CoreGraphics (`CGFloat`),
    /// which is available on both platforms; its math must produce identical
    /// results everywhere.
    func testMinimapGeometryMathIsStable() {
        let geo = MinimapGeometry(
            documentHeight: 1000,
            viewportHeight: 200,
            minimapHeight: 400,
            contentHeight: 300
        )
        XCTAssertEqual(geo.maxScrollOffset, 800, accuracy: 0.0001)
        XCTAssertEqual(geo.documentToMinimap, 0.3, accuracy: 0.0001)
    }

    /// `SyntaxTokenKind(captureName:)` longest-prefix matching is pure Foundation
    /// and must classify identically on every platform.
    func testTokenKindClassificationIsStable() {
        XCTAssertEqual(SyntaxTokenKind(captureName: "keyword.control"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "string"), .string)
        XCTAssertEqual(SyntaxTokenKind(captureName: "nonexistent.capture"), .plain)
    }
}
