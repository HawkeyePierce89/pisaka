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

    /// `FileTypeIcon`'s name table (special names, compound suffixes,
    /// extensions, the language phase and the fallback) is pure Foundation data,
    /// so it must answer identically on every platform — both draw the same
    /// assets through it.
    func testFileTypeIconResolutionIsStable() {
        XCTAssertEqual(FileTypeIcon.forFile(named: "package.json"), .nodejs)
        XCTAssertEqual(FileTypeIcon.forFile(named: "Sources/App/main.swift"), .swift)
        XCTAssertEqual(FileTypeIcon.forFile(named: "app.test.ts"), .testTS)
        XCTAssertEqual(FileTypeIcon.forFile(named: "file.zzz"), .document)
        XCTAssertEqual(FileTypeIcon.typescript.catalogName, "FileIcons/typescript")
    }

    /// `MinimapGeometry` and `TreeDraftDismissRule` are the two Core types backed
    /// by CoreGraphics (`CGFloat`, `CGPoint`/`CGRect`), which is available on both
    /// platforms; their math must produce identical results everywhere.
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

    /// The other CoreGraphics-backed Core type: `CGRect.contains` is half-open on
    /// every platform, and an empty rectangle contains nothing.
    func testTreeDraftDismissRuleGeometryIsStable() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 30)
        XCTAssertEqual(
            TreeDraftDismissRule.decision(clickedWindowIsDraftWindow: true,
                                          clickedInsideWindowContent: true,
                                          point: CGPoint(x: 10, y: 20),
                                          draftBounds: bounds),
            .ignore)
        XCTAssertEqual(
            TreeDraftDismissRule.decision(clickedWindowIsDraftWindow: true,
                                          clickedInsideWindowContent: true,
                                          point: CGPoint(x: 110, y: 50),
                                          draftBounds: bounds),
            .cancel)
        XCTAssertEqual(
            TreeDraftDismissRule.decision(clickedWindowIsDraftWindow: true,
                                          clickedInsideWindowContent: true,
                                          point: CGPoint(x: 10, y: 20),
                                          draftBounds: .zero),
            .cancel)
    }

    /// `SyntaxTokenKind(captureName:)` longest-prefix matching is pure Foundation
    /// and must classify identically on every platform.
    func testTokenKindClassificationIsStable() {
        XCTAssertEqual(SyntaxTokenKind(captureName: "keyword.control"), .keyword)
        XCTAssertEqual(SyntaxTokenKind(captureName: "string"), .string)
        XCTAssertEqual(SyntaxTokenKind(captureName: "nonexistent.capture"), .plain)
    }
}
