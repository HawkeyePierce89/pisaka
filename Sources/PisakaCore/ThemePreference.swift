/// The user's appearance preference: follow the system, or force light/dark.
///
/// A color/SwiftUI-free semantic enum (the `FileIconColor`/`BottomPanel`
/// precedent); the view layer maps it to a SwiftUI `ColorScheme?`
/// (`.system → nil`, `.light → .light`, `.dark → .dark`). Its `String` raw value
/// is the stable persisted form, so the cases must not be renamed.
public enum ThemePreference: String, CaseIterable, Equatable {
    case system
    case light
    case dark
}
