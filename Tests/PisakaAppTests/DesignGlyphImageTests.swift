#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The run-time half of the design glyphs, which the Core gate cannot see: the
/// compiled asset catalog actually carries every `DesignGlyph` as a template
/// image under its name, and the one helper sizes, centres and tints it as its
/// contract says. `DesignGlyphAssetTests` pins the catalog's *source*; this
/// suite reads what the build made of it, through the hosting app's bundle.
@MainActor
final class DesignGlyphImageTests: XCTestCase {

    func testEveryGlyphLoadsFromTheAppBundleAsATemplate() throws {
        for glyph in DesignGlyph.allCases {
            let image = try XCTUnwrap(NSImage(named: glyph.assetName),
                                      "\(glyph.assetName) did not compile into the app's asset catalog")
            XCTAssertTrue(image.isTemplate, "\(glyph.assetName) lost its template rendering intent")
        }
    }

    func testTheAppKitHalfFillsItsSquareWithTheTintAndNothingElse() throws {
        let tint = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let image = try XCTUnwrap(DesignGlyphDrawing.image(.x, pointSize: 22, tint: tint))
        XCTAssertEqual(image.size, NSSize(width: 22, height: 22))

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 44, pixelsHigh: 44, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        var inked = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                inked += 1
                let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(srgb.redComponent, 0.8, "an inked pixel is not the tint")
                XCTAssertLessThan(srgb.greenComponent, 0.2, "an inked pixel is not the tint")
            }
        }
        XCTAssertGreaterThan(inked, 0, "the glyph drew nothing")
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 0, accuracy: 0.01,
                       "the square's corner is outside the x glyph and must stay clear")
    }

    func testFittedRectKeepsTheAspectAndCentres() {
        let bounds = NSRect(x: 0, y: 0, width: 20, height: 20)
        XCTAssertEqual(DesignGlyphDrawing.fittedRect(for: NSSize(width: 11, height: 11), in: bounds), bounds)
        XCTAssertEqual(DesignGlyphDrawing.fittedRect(for: NSSize(width: 20, height: 10), in: bounds),
                       NSRect(x: 0, y: 5, width: 20, height: 10))
        XCTAssertEqual(DesignGlyphDrawing.fittedRect(for: .zero, in: bounds), bounds)
    }

    func testTheSwiftUIHalfOccupiesItsSlotAtTheInterfaceScale() throws {
        for scale in [1.0, 1.8] {
            let metrics = InterfaceMetrics(scale: scale)
            let view = DesignGlyphImage(.folder, slot: 16, role: .accent)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
            let host = NSHostingView(rootView: view)
            XCTAssertEqual(host.fittingSize.width, metrics.pt(16), "slot width at scale \(scale)")
            XCTAssertEqual(host.fittingSize.height, metrics.pt(16), "slot height at scale \(scale)")
        }
    }

    func testTheSwiftUIHalfDrawsTheGlyphAtItsSizeInTheRole() throws {
        let metrics = InterfaceMetrics(scale: 1.8)
        let slot = metrics.pt(24)
        let render = try HostedRender(
            size: CGSize(width: slot, height: slot),
            root: DesignGlyphImage(.folder, size: 12, slot: 24, role: .accent)
                .environment(\.interfaceMetrics, metrics)
                .environment(\.chromeTheme, ChromeTheme(.dark))
        )
        let column = slot / 2
        let extent = try XCTUnwrap(render.extent(atX: column) { color in
            (color?.alphaComponent ?? 0) > 0.5
        }, "the glyph drew nothing down its centre column")
        let drawn = extent.maxY - extent.minY
        XCTAssertLessThanOrEqual(drawn, metrics.pt(12) + 1, "the glyph is drawn larger than its size")
        XCTAssertGreaterThan(drawn, metrics.pt(12) / 2, "the glyph is drawn far smaller than its size")
        XCTAssertGreaterThan(extent.minY, 0, "a glyph smaller than its slot must be centred, not pinned to an edge")
        XCTAssertNotNil(render.extent(of: .accent, atX: column),
                        "the glyph is not tinted with the role its caller named")
    }
}
#endif
