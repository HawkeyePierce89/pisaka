import Foundation

/// The shared checkbox shape's measurements for a row drawn at the **code** font.
///
/// The chrome's checkbox is sized by the chrome's zone: `ChromeGeometry`'s
/// `checkboxSide` (14) and `checkboxCornerRadius` (3), scaled at the use site.
/// A checkbox that sits *on a code-font row* — the unified diff's per-line
/// toggle — belongs to the code zone
/// instead, and would drift out of proportion with its line if it followed the
/// chrome's zoom. So it is sized from the code font size alone, by the
/// proportion the chrome box already has against the chrome's default text:
/// a 14-pt box beside 13-pt text.
///
/// - `side` is `fontSize × 14 / 13`, so a 13-pt line carries exactly the
///   chrome box's 14.
/// - `glyphSide` is `side × 10 / 14`, the shared shape's glyph-to-box
///   proportion.
/// - `cornerRadius` is `checkboxCornerRadius × side / 14`.
/// - `strokeWidth` is `hairlineWidth × side / 14`, and never thinner than one
///   point, so the off box survives the bottom of the font range.
///
/// Every value lands on the half-point grid the chrome's layout metrics use — one
/// device pixel on the displays this app is drawn on — and each derived value
/// is computed from the *rounded* side, so the four always describe one box.
/// `placeholderWidth`, the width a row without a checkbox reserves so its text
/// starts where a checked row's does, is the side by definition.
///
/// The rule deliberately knows nothing about the chrome's zone: the code zone
/// and the chrome's must not interact (`core-zoom.md`), so a box on a code row
/// is the same size however far the chrome is zoomed.
public struct CodeZoneCheckboxRule: Equatable, Hashable, Sendable {
    /// The chrome box's side against the chrome's default text size.
    static let referenceSide: Double = 14
    static let referenceFontSize: Double = 13
    /// The shared shape's glyph side at the reference box.
    static let referenceGlyphSide: Double = 10

    public let side: Double
    public let glyphSide: Double
    public let cornerRadius: Double
    public let strokeWidth: Double

    /// The width a row without a box reserves in the box's place.
    public var placeholderWidth: Double { side }

    /// `fontSize` is clamped to the code zone's range first, so a corrupt value
    /// can never reach a layout.
    public init(fontSize: Double) {
        let font = ZoomScaleRule.editorFont.clamp(fontSize)
        let side = Self.halfPoint(font * Self.referenceSide / Self.referenceFontSize)
        let ratio = side / Self.referenceSide
        self.side = side
        glyphSide = Self.halfPoint(Self.referenceGlyphSide * ratio)
        cornerRadius = Self.halfPoint(ChromeGeometry.checkboxCornerRadius * ratio)
        strokeWidth = Swift.max(1, Self.halfPoint(ChromeGeometry.hairlineWidth * ratio))
    }

    private static func halfPoint(_ value: Double) -> Double {
        (value * 2).rounded() / 2
    }
}
