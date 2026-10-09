#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The matched-pair overlay, read off the layout manager that paints it.
///
/// The editor's real TextKit 1 stack (`EditorLayoutHarness`), no window. Three
/// readings of one claim — the pair draws the chrome's `bracketMatch` role:
/// the temporary `.backgroundColor` both halves carry after `setPairRanges`,
/// resolved under each appearance; a bitmap sample inside the open bracket's
/// cell, rendered through `cacheDisplay` the way `CurrentLineHighlightTests`
/// samples its wash, with the same 3/255 tolerance; and the contrast every
/// colour drawn *on* the pair keeps over it — the five rainbow depth colours and
/// the unmatched-bracket red, each at least 3:1 in both appearances, computed
/// by `ContrastArithmetic` from the role's table entry and the code zone's own
/// resolved colours rather than by any converter under test.
@MainActor
final class BracketPairBackgroundTests: XCTestCase {
    private let text = "f(x)\n"
    private let open = NSRange(location: 1, length: 1)
    private let close = NSRange(location: 3, length: 1)

    func testBothHalvesOfThePairCarryTheRoleInBothAppearances() throws {
        let harness = makeHarness(.light)
        harness.layoutManager.setPairRanges([open, close])
        for appearance in ChromeAppearance.allCases {
            let expected = try rgb(ChromePalette.nsColor(.bracketMatch, in: appearance))
            for half in [open, close] {
                let painted = try XCTUnwrap(
                    harness.layoutManager.temporaryAttribute(
                        .backgroundColor, atCharacterIndex: half.location, effectiveRange: nil
                    ) as? NSColor,
                    "no background on the pair's half at \(half.location)"
                )
                XCTAssertEqual(try rgb(resolved(painted, in: appearance)), expected, "half at \(half.location), \(appearance)")
            }
        }
        XCTAssertNil(
            harness.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: 2, effectiveRange: nil),
            "the text between the brackets is painted"
        )
    }

    func testTheOpenBracketsCellIsDrawnInTheRole() throws {
        for appearance in ChromeAppearance.allCases {
            let harness = makeHarness(appearance)
            harness.layoutManager.setPairRanges([open, close])
            let rep = try bitmap(of: harness.textView, appearance: appearance)
            let expected = try rgb(ChromePalette.nsColor(.bracketMatch, in: appearance))
            XCTAssertTrue(
                try sample(rep, harness: harness, cellOf: open.location, matches: expected),
                "the open bracket's cell is not drawn in bracketMatch, \(appearance)"
            )
            XCTAssertFalse(
                try sample(rep, harness: harness, cellOf: 2, matches: expected),
                "the cell between the brackets is drawn in bracketMatch, \(appearance)"
            )
        }
    }

    func testEveryColourDrawnOnThePairClearsThreeToOne() throws {
        let entry = ChromePalette.entry(for: .bracketMatch)
        let theme = SyntaxTheme.shared
        for appearance in ChromeAppearance.allCases {
            let ground = appearance == .dark ? entry.dark : entry.light
            var drawn = try (0..<theme.bracketDepthColors.count).map { depth in
                ("depth \(depth)", try rgb(resolved(theme.nsBracketColor(forDepth: depth), in: appearance)))
            }
            drawn.append(("unmatched", try rgb(resolved(theme.nsUnmatchedBracketColor, in: appearance))))
            XCTAssertEqual(drawn.count, 6, "five depth colours plus the unmatched red")
            for (name, colour) in drawn {
                let ratio = ContrastArithmetic.contrast(colour, ground)
                XCTAssertGreaterThanOrEqual(
                    ratio, 3,
                    "\(name) (\(String(colour, radix: 16))) over bracketMatch is \(ratio):1, \(appearance)"
                )
            }
        }
    }

    // MARK: - Harness

    private func makeHarness(_ appearance: ChromeAppearance) -> EditorLayoutHarness {
        let harness = EditorLayoutHarness()
        harness.scrollView.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        harness.textView.font = .monospacedSystemFont(ofSize: 24, weight: .regular)
        harness.textView.minSize = NSSize(width: 300, height: 100)
        harness.textView.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        harness.textView.drawsBackground = false
        harness.textView.string = text
        harness.layOut()
        return harness
    }

    private func appearanceNamed(_ appearance: ChromeAppearance) -> NSAppearance {
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)!
    }

    private func resolved(_ color: NSColor, in appearance: ChromeAppearance) -> NSColor {
        var result = color
        appearanceNamed(appearance).performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    /// A colour as `0xRRGGBB`, each component rounded to 8 bits.
    private func rgb(_ color: NSColor) throws -> UInt32 {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB), "the colour is not representable in sRGB")
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(srgb.redComponent) << 16 | byte(srgb.greenComponent) << 8 | byte(srgb.blueComponent)
    }

    private func bitmap(of view: NSView, appearance: ChromeAppearance) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearanceNamed(appearance).performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep
    }

    /// Sample one point inside a character's cell, just inside its top-leading
    /// corner — the background fills the whole cell, the glyph's ink does not
    /// reach that corner.
    private func sample(
        _ rep: NSBitmapImageRep,
        harness: EditorLayoutHarness,
        cellOf index: Int,
        matches expected: UInt32
    ) throws -> Bool {
        let layoutManager = harness.layoutManager
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let cell = layoutManager.boundingRect(forGlyphRange: glyphs, in: harness.textContainer)
        let origin = harness.textView.textContainerOrigin
        let point = NSPoint(x: cell.minX + origin.x + 2, y: fragment.minY + origin.y + 2)
        let view = harness.textView
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let row = view.isFlipped ? Int(point.y * scale) : rep.pixelsHigh - 1 - Int(point.y * scale)
        let color = try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: row)?.usingColorSpace(.sRGB))
        let tolerance: CGFloat = 3 / 255
        let red = CGFloat(expected >> 16 & 0xFF) / 255
        let green = CGFloat(expected >> 8 & 0xFF) / 255
        let blue = CGFloat(expected & 0xFF) / 255
        return abs(color.redComponent - red) <= tolerance
            && abs(color.greenComponent - green) <= tolerance
            && abs(color.blueComponent - blue) <= tolerance
    }
}
#endif
