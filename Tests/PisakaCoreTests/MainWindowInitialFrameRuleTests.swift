import PisakaCore
import XCTest

final class MainWindowInitialFrameRuleTests: XCTestCase {
    private typealias Rule = MainWindowInitialFrameRule

    func testA1440By875VisibleFrameGivesThreeQuartersCentred() {
        let frame = Rule.frame(
            visible: .init(x: 0, y: 0, width: 1440, height: 875),
            minimumWidth: 960,
            minimumHeight: 600
        )
        XCTAssertEqual(frame, .init(x: 180, y: 109, width: 1080, height: 656))
    }

    func testTheFrameStaysInsideTheVisibleFrame() throws {
        let visible = Rule.Rect(x: 0, y: 0, width: 1440, height: 875)
        let frame = try XCTUnwrap(Rule.frame(visible: visible, minimumWidth: 0, minimumHeight: 0))
        XCTAssertGreaterThanOrEqual(frame.x, visible.x)
        XCTAssertGreaterThanOrEqual(frame.y, visible.y)
        XCTAssertLessThanOrEqual(frame.x + frame.width, visible.x + visible.width)
        XCTAssertLessThanOrEqual(frame.y + frame.height, visible.y + visible.height)
    }

    func testAMinimumAboveTheShareRaisesTheFrame() {
        let frame = Rule.frame(
            visible: .init(x: 0, y: 0, width: 1440, height: 875),
            minimumWidth: 1200,
            minimumHeight: 700
        )
        XCTAssertEqual(frame, .init(x: 120, y: 87, width: 1200, height: 700))
    }

    func testAMinimumAboveTheVisibleFrameIsCappedByIt() {
        let frame = Rule.frame(
            visible: .init(x: 0, y: 0, width: 1280, height: 775),
            minimumWidth: 1500,
            minimumHeight: 900
        )
        XCTAssertEqual(frame, .init(x: 0, y: 0, width: 1280, height: 775))
    }

    func testEachAxisIsDecidedSeparately() {
        let frame = Rule.frame(
            visible: .init(x: 0, y: 0, width: 1440, height: 875),
            minimumWidth: 100,
            minimumHeight: 2000
        )
        XCTAssertEqual(frame, .init(x: 180, y: 0, width: 1080, height: 875))
    }

    func testANonZeroOriginIsRespected() {
        let frame = Rule.frame(
            visible: .init(x: 1440, y: 25, width: 1920, height: 1055),
            minimumWidth: 960,
            minimumHeight: 600
        )
        XCTAssertEqual(frame, .init(x: 1440 + 240, y: 25 + 132, width: 1440, height: 791))
    }

    func testANegativeOriginIsRespected() {
        let frame = Rule.frame(
            visible: .init(x: -1440, y: -100, width: 1440, height: 875),
            minimumWidth: 0,
            minimumHeight: 0
        )
        XCTAssertEqual(frame, .init(x: -1440 + 180, y: -100 + 109, width: 1080, height: 656))
    }

    func testAZeroSizeVisibleFrameHasNoAnswer() {
        XCTAssertNil(Rule.frame(visible: .init(x: 0, y: 0, width: 0, height: 0), minimumWidth: 960, minimumHeight: 600))
        XCTAssertNil(Rule.frame(visible: .init(x: 0, y: 0, width: 1440, height: 0), minimumWidth: 960, minimumHeight: 600))
        XCTAssertNil(Rule.frame(visible: .init(x: 0, y: 0, width: -10, height: 875), minimumWidth: 960, minimumHeight: 600))
    }

    func testANonFiniteVisibleFrameHasNoAnswer() {
        XCTAssertNil(Rule.frame(visible: .init(x: .nan, y: 0, width: 1440, height: 875), minimumWidth: 0, minimumHeight: 0))
        XCTAssertNil(Rule.frame(
            visible: .init(x: 0, y: 0, width: .infinity, height: 875),
            minimumWidth: 0,
            minimumHeight: 0
        ))
    }

    func testANonFiniteMinimumIsIgnored() {
        let frame = Rule.frame(
            visible: .init(x: 0, y: 0, width: 1440, height: 875),
            minimumWidth: .infinity,
            minimumHeight: .nan
        )
        XCTAssertEqual(frame, .init(x: 180, y: 109, width: 1080, height: 656))
    }

    func testFractionalExtentsLandOnWholePoints() throws {
        let frame = try XCTUnwrap(Rule.frame(
            visible: .init(x: 0, y: 0, width: 1001, height: 777),
            minimumWidth: 0,
            minimumHeight: 0
        ))
        for value in [frame.x, frame.y, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(.down))
        }
    }
}
