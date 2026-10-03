#if os(macOS)
import AppKit
import SwiftUI

/// The one resolver of the code font: every code-zone surface — the editor,
/// the diff and merge panes, the source viewer, the completion and hover
/// popovers, the commit dialog's diff and Find in Files' preview lines — builds
/// its font here, from `SettingsStore.fontSize` and
/// `SettingsStore.editorFontFamily`. The terminal keeps its own font; it is a
/// zone of its own.
///
/// A family is honoured only when it is installed **and** fixed-pitch; anything
/// else — `nil`, a family uninstalled since it was chosen, a proportional one
/// typed into a launch argument — is today's system monospaced font. The
/// question is asked every time a font is built rather than once when the
/// family is chosen, so the stored choice survives an uninstall and comes back
/// with a reinstall.
enum EditorFont {
    /// The code font at `size`, in `family` when that family is installed and
    /// fixed-pitch, otherwise the system monospaced font.
    static func font(size: CGFloat, family: String?) -> NSFont {
        if let family, let named = installedFixedPitchFont(family: family, size: size) {
            return named
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The same font for a SwiftUI site, so the two kinds of surface cannot
    /// disagree about which family is current.
    static func swiftUIFont(size: CGFloat, family: String?) -> Font {
        Font(font(size: size, family: family) as CTFont)
    }

    /// The installed fixed-pitch families, sorted by name, for the Preferences
    /// menu. A family is listed only when `font(size:family:)` honours it, so
    /// choosing an entry never silently draws the fallback: the font manager's
    /// fixed-pitch set narrows the candidates cheaply (a family with one
    /// fixed-pitch member can still have a proportional regular one), and the
    /// resolver's own test decides.
    static func installedFixedPitchFamilies() -> [String] {
        let manager = NSFontManager.shared
        let fixedPitchNames = Set(manager.availableFontNames(with: .fixedPitchFontMask) ?? [])
        return manager.availableFontFamilies
            .filter { family in
                (manager.availableMembers(ofFontFamily: family) ?? []).contains { member in
                    (member.first as? String).map(fixedPitchNames.contains) ?? false
                }
            }
            .filter { installedFixedPitchFont(family: $0, size: NSFont.systemFontSize) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The regular member of `family` at `size`, or `nil` when the family is not
    /// installed or is not fixed-pitch.
    private static func installedFixedPitchFont(family: String, size: CGFloat) -> NSFont? {
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size),
              font.familyName == family,
              font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        else { return nil }
        return font
    }
}
#endif
