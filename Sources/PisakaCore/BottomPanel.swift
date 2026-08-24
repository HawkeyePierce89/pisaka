/// Which bottom dock panel is currently shown, VS Code-style.
///
/// The Terminal, Git Log, Local Changes, and Problems are bottom dock panels
/// above an always-visible bar; a `BottomPanel?` of `nil` means the panel is
/// hidden. The view layer owns the bar and the panels; this enum plus the pure
/// `toggled(_:selecting:)` helper are the only stateful logic, so they live in
/// Core and are unit-tested (the color-free / pure-logic precedent of
/// `FileIconColor`/`LogFilter`).
public enum BottomPanel: Equatable {
    case terminal
    case log
    case changes
    case problems

    /// Toggle the panel for a clicked/triggered `target`: clicking the panel
    /// that is already shown collapses it (`nil`), otherwise the `target` panel
    /// is shown — so a button or its matching menu command behaves identically.
    public static func toggled(_ current: BottomPanel?, selecting target: BottomPanel) -> BottomPanel? {
        current == target ? nil : target
    }
}
