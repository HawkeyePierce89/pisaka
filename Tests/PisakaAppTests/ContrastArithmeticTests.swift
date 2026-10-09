#if os(macOS)
import XCTest

/// The shared contrast arithmetic against values with known answers, so a
/// suite pinning a colour table through it measures with a checked stick.
final class ContrastArithmeticTests: XCTestCase {

    func testBlackOnWhiteIsTwentyOneToOneAndSymmetric() {
        XCTAssertEqual(ContrastArithmetic.contrast(0x000000, 0xFFFFFF), 21, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.contrast(0xFFFFFF, 0x000000), 21, accuracy: 1e-9)
        XCTAssertEqual(
            ContrastArithmetic.contrast(0x2F64C8, 0xECECEF),
            ContrastArithmetic.contrast(0xECECEF, 0x2F64C8),
            accuracy: 1e-12
        )
    }

    func testAColourAgainstItselfIsOneToOne() {
        XCTAssertEqual(ContrastArithmetic.contrast(0x777777, 0x777777), 1, accuracy: 1e-12)
    }

    /// `#777777` on white is the well-known 4.48:1, just under the 4.5 text floor.
    func testKnownMidGrey() {
        XCTAssertEqual(ContrastArithmetic.contrast(0x777777, 0xFFFFFF), 4.48, accuracy: 0.01)
        XCTAssertEqual(ContrastArithmetic.luminance(0x777777), 0.1845, accuracy: 0.0005)
    }

    func testLinearisationBranchBelowTheKnee() {
        // 10/255 ≈ 0.0392 sits below 0.04045, so it takes the linear segment.
        XCTAssertEqual(ContrastArithmetic.luminance(0x0A0A0A), (10.0 / 255) / 12.92, accuracy: 1e-12)
    }

    func testPrimaryHues() {
        XCTAssertEqual(ContrastArithmetic.hue(0xFF0000), 0, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hue(0x00FF00), 120, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hue(0x0000FF), 240, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hue(0xFF00FF), 300, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hue(0x808080), 0, accuracy: 1e-9)
    }

    func testHueSeparationWrapsAroundTheCircle() {
        XCTAssertEqual(ContrastArithmetic.hueSeparation(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hueSeparation(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hueSeparation(0, 180), 180, accuracy: 1e-9)
        XCTAssertEqual(ContrastArithmetic.hueSeparation(90, 120), 30, accuracy: 1e-9)
    }
}

#endif
