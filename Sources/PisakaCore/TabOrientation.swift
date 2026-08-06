/// How the open-tabs list is laid out: a vertical column (the default,
/// VS Code-style sidebar) or a horizontal strip above the editor.
///
/// A color/SwiftUI-free semantic enum (the `FileIconColor`/`BottomPanel`
/// precedent); the view layer reads it to pick a layout. Its `String` raw value
/// is the stable persisted form, so the cases must not be renamed.
public enum TabOrientation: String, CaseIterable, Equatable {
    case vertical
    case horizontal
}
