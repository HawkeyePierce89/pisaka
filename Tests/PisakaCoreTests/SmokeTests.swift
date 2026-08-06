import XCTest
@testable import PisakaCore

final class SmokeTests: XCTestCase {
    func testVersionConstantExists() {
        XCTAssertEqual(PisakaCore.version, "0.1.0")
    }
}
