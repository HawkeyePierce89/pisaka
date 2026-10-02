import XCTest
@testable import PisakaCore

final class DesignGlyphTests: XCTestCase {

    func testAssetNameIsTheRawValue() {
        for glyph in DesignGlyph.allCases {
            XCTAssertEqual(glyph.assetName, glyph.rawValue)
        }
        XCTAssertEqual(DesignGlyph.gitPullRequestArrow.assetName, "git-pull-request-arrow")
        XCTAssertEqual(DesignGlyph.undo2.assetName, "undo-2")
        XCTAssertEqual(DesignGlyph.x.assetName, "x")
    }

    func testAssetNamesAreUnique() {
        let names = DesignGlyph.allCases.map(\.assetName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, 24)
    }

    func testNativeSizesAreTheExportedOnes() {
        XCTAssertEqual(DesignGlyph.package.nativeSize, 11)
        XCTAssertEqual(DesignGlyph.chevronDown.nativeSize, 11)
        XCTAssertEqual(DesignGlyph.folder.nativeSize, 12)
        XCTAssertEqual(DesignGlyph.fileCode.nativeSize, 12)
        XCTAssertEqual(DesignGlyph.refreshCw.nativeSize, 13)
        XCTAssertEqual(DesignGlyph.undo2.nativeSize, 13)
        XCTAssertEqual(DesignGlyph.regex.nativeSize, 14)
        XCTAssertEqual(DesignGlyph.wholeWord.nativeSize, 14)
    }

    func testAGlyphRoundTripsThroughItsAssetName() {
        for glyph in DesignGlyph.allCases {
            XCTAssertEqual(DesignGlyph(rawValue: glyph.assetName), glyph)
        }
        XCTAssertNil(DesignGlyph(rawValue: "chevron-left"))
    }
}
