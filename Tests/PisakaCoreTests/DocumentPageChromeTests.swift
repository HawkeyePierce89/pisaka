import XCTest
@testable import PisakaCore

/// The one chrome value both served document pages take: the role table, the
/// role-driven fill, and the restated fallback blocks' shape. That the restated
/// blocks equal the palette is asserted app-side (`ChromePaletteTests`), where
/// the palette lives.
final class DocumentPageChromeTests: XCTestCase {

    // MARK: - The role table

    /// Pinned field by field: a page meaning moving to another role is a design
    /// decision, and it fails here first.
    func testTheRoleTableIsPinnedExactly() {
        XCTAssertEqual(DocumentPageChrome.role(for: .background), .bgEditor)
        XCTAssertEqual(DocumentPageChrome.role(for: .text), .textPrimary)
        XCTAssertEqual(DocumentPageChrome.role(for: .secondaryText), .textSecondary)
        XCTAssertEqual(DocumentPageChrome.role(for: .link), .accent)
        XCTAssertEqual(DocumentPageChrome.role(for: .codeBackground), .bgCanvas)
        XCTAssertEqual(DocumentPageChrome.role(for: .border), .hairline)
        XCTAssertEqual(DocumentPageChrome.Field.allCases.count, 6)
    }

    /// Six meanings, six roles. The page ground and the code ground in
    /// particular: a code block draws no border, so the two grounds are the
    /// only thing separating it from the page.
    func testTheSixRolesAreDistinctAndThePageGroundDiffersFromTheCodeGround() {
        let roles = DocumentPageChrome.Field.allCases.map(DocumentPageChrome.role(for:))
        XCTAssertEqual(Set(roles).count, roles.count)
        XCTAssertNotEqual(
            DocumentPageChrome.role(for: .background),
            DocumentPageChrome.role(for: .codeBackground)
        )
    }

    // MARK: - The role-driven fill

    func testTheFillRoutesEachFieldThroughItsOwnRole() {
        let chrome = DocumentPageChrome(appearance: .dark) { $0.rawValue }
        for field in DocumentPageChrome.Field.allCases {
            XCTAssertEqual(chrome[field], DocumentPageChrome.role(for: field).rawValue, "\(field)")
        }
    }

    func testColorSchemeFollowsTheAppearance() {
        XCTAssertEqual(DocumentPageChrome(appearance: .dark) { _ in "x" }.colorScheme, "dark")
        XCTAssertEqual(DocumentPageChrome(appearance: .light) { _ in "x" }.colorScheme, "light")
        XCTAssertEqual(DocumentPageChrome.dark.colorScheme, "dark")
        XCTAssertEqual(DocumentPageChrome.light.colorScheme, "light")
    }

    // MARK: - The restated blocks

    func testLightAndDarkDifferOnEveryColourField() {
        for field in DocumentPageChrome.Field.allCases {
            XCTAssertNotEqual(DocumentPageChrome.light[field], DocumentPageChrome.dark[field], "\(field)")
        }
    }

    func testTheRestatedBlocksAreLowercaseSixDigitHex() throws {
        let shape = try NSRegularExpression(pattern: "^#[0-9a-f]{6}$")
        for chrome in [DocumentPageChrome.light, .dark] {
            for field in DocumentPageChrome.Field.allCases {
                let value = chrome[field]
                let range = NSRange(value.startIndex..., in: value)
                XCTAssertNotNil(shape.firstMatch(in: value, range: range), "\(field): \(value)")
            }
        }
    }

    func testResolvedCoversAllThreePreferences() {
        XCTAssertEqual(DocumentPageChrome.resolved(.light, systemPrefersDark: true), .light)
        XCTAssertEqual(DocumentPageChrome.resolved(.dark, systemPrefersDark: false), .dark)
        XCTAssertEqual(DocumentPageChrome.resolved(.system, systemPrefersDark: true), .dark)
        XCTAssertEqual(DocumentPageChrome.resolved(.system, systemPrefersDark: false), .light)
    }
}
