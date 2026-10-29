#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The run-time half of the vendored file-type icons, which the Core gate
/// cannot see: the compiled asset catalog actually carries every `FileTypeIcon`
/// under its namespaced `catalogName`, with its original rendering intent; every
/// one of them draws ink once compiled; the one helper draws an icon in the
/// asset's own colours whatever the theme; and its 14-point square sits inside
/// the body font's line, which the Problems, Usages and Log rows rely on.
/// `FileTypeIconAssetTests` pins the catalog's *source*; this suite reads what
/// the build made of it, through the hosting app's bundle.
///
/// **Cheap by construction.** The asset checks draw into one bitmap context
/// created once and cleared between icons, and the layout gate measures through
/// `NSHostingController.sizeThatFits`, so the suite opens no window except the
/// two `HostedRender`s of the theme check.
@MainActor
final class FileTypeIconImageTests: XCTestCase {

    func testEveryIconLoadsFromTheAppBundleAsAnOriginalImage() throws {
        for icon in FileTypeIcon.allCases {
            let image = try XCTUnwrap(NSImage(named: icon.catalogName),
                                      "\(icon.catalogName) did not compile into the app's asset catalog")
            XCTAssertFalse(image.isTemplate, "\(icon.catalogName) is a template — its colours would be dropped")
        }
    }

    /// One 32×32 context for all 59: each icon is drawn once into the cleared
    /// bitmap and must leave at least one fully opaque pixel. A guard against a
    /// catalog compiler (or an update) dropping an icon's ink silently —
    /// `kotlin`'s gradient fill is the one at risk.
    func testEveryIconDrawsInk() throws {
        let canvas = try Canvas(side: 32)
        for icon in FileTypeIcon.allCases {
            let image = try XCTUnwrap(NSImage(named: icon.catalogName), icon.catalogName)
            canvas.draw(image)
            XCTAssertGreaterThan(canvas.opaquePixels().count, 0, "\(icon.catalogName) drew no opaque ink")
        }
    }

    /// `typescript` is one colour, `#0288d1`, its letters cut out of the
    /// square: every opaque pixel is that saturated blue — not grey, and not a
    /// role.
    func testTypescriptDrawsItsOwnBlue() throws {
        let canvas = try Canvas(side: 48)
        canvas.draw(try XCTUnwrap(NSImage(named: FileTypeIcon.typescript.catalogName)))
        let opaque = canvas.opaquePixels()
        XCTAssertFalse(opaque.isEmpty, "typescript drew nothing")
        for pixel in opaque {
            XCTAssertTrue(Self.isTypescriptBlue(pixel), "an inked typescript pixel is not its blue: \(pixel)")
        }
    }

    /// `document`'s root says `fill="none"`, which its full-square first path
    /// inherits: honoured, the square's corner stays transparent.
    func testDocumentLeavesItsCornerTransparent() throws {
        let canvas = try Canvas(side: 48)
        canvas.draw(try XCTUnwrap(NSImage(named: FileTypeIcon.document.catalogName)))
        XCTAssertFalse(canvas.opaquePixels().isEmpty, "document drew nothing")
        XCTAssertEqual(canvas.alpha(x: 0, y: 0), 0, "document's corner is inked — the root fill=\"none\" was lost")
    }

    /// The helper under each appearance: the ink is the same blue in both, so
    /// nothing in the chrome's theme reaches the icon.
    func testTheHelperDrawsTheSameColoursInBothAppearances() throws {
        let metrics = InterfaceMetrics(scale: 1)
        var averages: [ChromeAppearance: (red: CGFloat, green: CGFloat, blue: CGFloat)] = [:]
        for appearance in [ChromeAppearance.dark, .light] {
            let side = metrics.scaled(14)
            let render = try HostedRender(
                size: CGSize(width: side, height: side),
                root: FileTypeIconImage(.typescript, side: 14)
                    .environment(\.interfaceMetrics, metrics)
                    .environment(\.chromeTheme, ChromeTheme(appearance))
                    .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            )
            addTeardownBlock { @MainActor in render.window.close() }
            let step = 1 / render.pixelScale
            var inked: [NSColor] = []
            for py in stride(from: 0, to: side, by: step) {
                for px in stride(from: 0, to: side, by: step) {
                    guard let color = render.color(atX: px, y: py)?.usingColorSpace(.sRGB),
                          color.alphaComponent > 0.95 else { continue }
                    inked.append(color)
                }
            }
            XCTAssertFalse(inked.isEmpty, "the helper drew no ink under \(appearance)")
            for color in inked {
                XCTAssertTrue(Self.isTypescriptBlue(color), "an inked pixel under \(appearance) is not the icon's blue")
            }
            let count = CGFloat(max(inked.count, 1))
            averages[appearance] = (
                inked.map(\.redComponent).reduce(0, +) / count,
                inked.map(\.greenComponent).reduce(0, +) / count,
                inked.map(\.blueComponent).reduce(0, +) / count
            )
        }
        let dark = try XCTUnwrap(averages[.dark]), light = try XCTUnwrap(averages[.light])
        XCTAssertEqual(dark.red, light.red, accuracy: 0.01, "the theme reached the icon's colour")
        XCTAssertEqual(dark.green, light.green, accuracy: 0.01, "the theme reached the icon's colour")
        XCTAssertEqual(dark.blue, light.blue, accuracy: 0.01, "the theme reached the icon's colour")
    }

    /// The 14-point square beside a body-medium label fits to the label's own
    /// height, at scale 1.0 and at the interface zone's maximum: the property the
    /// Problems and Usages headers and the Log's file row rely on to keep their
    /// height when the symbol they drew became this icon.
    func testTheFourteenPointSlotSitsInsideTheBodyLine() {
        for scale in [1.0, ZoomScaleRule.interfaceScale.maximum] {
            let metrics = InterfaceMetrics(scale: scale)
            let label = Text("Sources/App/main.swift").font(metrics.scaledFont(.body, weight: .medium))
            let alone = Self.fittingHeight(label.environment(\.interfaceMetrics, metrics))
            let row = HStack(spacing: metrics.scaled(4)) {
                FileTypeIconImage(.swift, side: 14)
                label
            }
            let beside = Self.fittingHeight(row.environment(\.interfaceMetrics, metrics))
            XCTAssertEqual(beside, alone, "the 14-point icon grows the body line at scale \(scale)")
        }
    }

    // MARK: - Helpers

    private static func fittingHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
            .height
    }

    /// `#0288d1` as drawn: a saturated blue, nowhere near grey.
    private static func isTypescriptBlue(_ color: NSColor) -> Bool {
        guard let srgb = color.usingColorSpace(.sRGB) else { return false }
        return srgb.blueComponent > 0.7 && srgb.redComponent < 0.15
            && srgb.greenComponent > 0.4 && srgb.greenComponent < 0.65
    }

    /// One square bitmap, drawn into and cleared in place.
    private final class Canvas {
        let rep: NSBitmapImageRep
        let side: Int

        init(side: Int) throws {
            self.side = side
            rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        }

        /// Clears the bitmap, then draws `image` fitted to the whole square.
        func draw(_ image: NSImage) {
            if let data = rep.bitmapData { memset(data, 0, rep.bytesPerRow * rep.pixelsHigh) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
        }

        /// The alpha byte at (`x`, `y`).
        func alpha(x: Int, y: Int) -> UInt8 {
            guard let data = rep.bitmapData else { return 0 }
            return data[y * rep.bytesPerRow + x * 4 + 3]
        }

        /// Every fully opaque pixel, as a colour.
        func opaquePixels() -> [NSColor] {
            var pixels: [NSColor] = []
            for y in 0..<side {
                for x in 0..<side where alpha(x: x, y: y) == 255 {
                    if let color = rep.colorAt(x: x, y: y) { pixels.append(color) }
                }
            }
            return pixels
        }
    }
}
#endif
