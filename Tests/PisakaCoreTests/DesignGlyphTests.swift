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
        XCTAssertEqual(names.count, 25)
    }

    func testAGlyphRoundTripsThroughItsAssetName() {
        for glyph in DesignGlyph.allCases {
            XCTAssertEqual(DesignGlyph(rawValue: glyph.assetName), glyph)
        }
        XCTAssertNil(DesignGlyph(rawValue: "chevron-left"))
    }
}
