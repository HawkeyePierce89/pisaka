#if os(macOS)
import AppKit
import XCTest
@testable import Pisaka

/// `EditorFont`, the one resolver of the code font: a named family is honoured
/// only when it is installed and fixed-pitch, and every other answer is the
/// system monospaced font at the same size.
///
/// Menlo and Helvetica both ship with every supported macOS, so the two
/// families this suite names cannot be missing from the machine running it.
final class EditorFontTests: XCTestCase {
    private static let system = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    func testNoFamilyIsTheSystemMonospacedFont() {
        let font = EditorFont.font(size: 15, family: nil)
        XCTAssertEqual(font.fontName, Self.system.fontName)
        XCTAssertEqual(font.pointSize, 15)
    }

    func testAnUnknownFamilyFallsBackToTheSystemMonospacedFont() {
        let font = EditorFont.font(size: 15, family: "No Such Family 7f3a")
        XCTAssertEqual(font.fontName, Self.system.fontName)
        XCTAssertEqual(font.pointSize, 15)
    }

    func testAnInstalledProportionalFamilyFallsBack() {
        let font = EditorFont.font(size: 15, family: "Helvetica")
        XCTAssertEqual(font.fontName, Self.system.fontName, "a proportional family must never draw code")
    }

    func testAnInstalledFixedPitchFamilyIsHonouredAtTheRequestedSize() {
        let font = EditorFont.font(size: 17, family: "Menlo")
        XCTAssertEqual(font.familyName, "Menlo")
        XCTAssertEqual(font.pointSize, 17)
        XCTAssertTrue(font.isFixedPitch)
    }

    func testTheMenuListsFixedPitchFamiliesAndNoProportionalOne() {
        let families = EditorFont.installedFixedPitchFamilies()
        XCTAssertTrue(families.contains("Menlo"))
        XCTAssertFalse(families.contains("Helvetica"))
        XCTAssertEqual(families, families.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        // Every family the menu offers is one the resolver honours, so choosing
        // an entry can never silently draw the fallback.
        for family in families {
            XCTAssertEqual(EditorFont.font(size: 13, family: family).familyName, family, family)
        }
    }
}
#endif
