import Foundation

/// The three independently persisted zoom zones.
///
/// A zone is *what a gesture grows*, not *where the gesture happened*: the
/// pointer picks a zone (`resolve(pointer:focusedSurface:)`), and every zone is
/// backed by exactly one persisted scale in `SettingsStore`. `code` is the
/// shared editor font size that already exists — there is deliberately no
/// second "code zoom" setting beside it — `terminal` the terminal font size,
/// and `interface` the chrome scale everything else is drawn at.
public enum ZoomZone: String, CaseIterable, Hashable, Sendable {
    case code
    case terminal
    case interface
}

/// What a *surface* under the pointer can be.
///
/// Only two cases, on purpose: `interface` is the answer when no surface was
/// hit, never a surface in its own right. Modelling it as a third case would
/// make "an interface surface nested inside a code surface" representable and
/// force every hit-test walker to decide what that means; here the question
/// cannot be asked. `zone` is the one-way widening into `ZoomZone`.
public enum ZoomSurfaceKind: String, CaseIterable, Hashable, Sendable {
    case code
    case terminal

    public var zone: ZoomZone {
        switch self {
        case .code: return .code
        case .terminal: return .terminal
        }
    }
}

/// One surface found under the pointer, with how deep in the window's view tree
/// it sits (the window's content view is depth 0, each child one deeper).
///
/// Depth is what makes nesting decidable without the resolver knowing anything
/// about views: a terminal inside the bottom panel's chrome, or an editor inside
/// a scroll view inside a split view, are just candidates at different depths.
public struct ZoomSurfaceCandidate: Equatable, Hashable, Sendable {
    public let kind: ZoomSurfaceKind
    public let depth: Int

    public init(kind: ZoomSurfaceKind, depth: Int) {
        self.kind = kind
        self.depth = depth
    }
}

/// Where the pointer was when the gesture arrived.
///
/// `insideApp` carries every conforming surface under the pointer in the
/// frontmost *app* window — possibly none, which is the ordinary case over the
/// project tree or a toolbar. `outsideApp` covers both "over another
/// application's window" and "off every window", which the menu shortcuts can
/// reach because a key equivalent fires wherever the pointer is.
public enum ZoomPointerLocation: Equatable, Hashable, Sendable {
    case insideApp([ZoomSurfaceCandidate])
    case outsideApp
}

extension ZoomZone {
    /// Which zone a gesture targets.
    ///
    /// The rules, in order:
    ///
    /// - `insideApp` with candidates: the **deepest** candidate wins. Depth is
    ///   containment, so the innermost surface the pointer is actually over is
    ///   the one the user means — a terminal drawn inside a panel that is itself
    ///   inside a split view zooms the terminal, not whatever encloses it.
    /// - **Ties resolve to the first candidate in scan order.** Two surfaces of
    ///   different kinds at the same depth overlapping the same point is not a
    ///   layout this app produces; rather than leave it undefined, the caller's
    ///   scan order (front-to-back within a window, `NSView.subviews` order for
    ///   siblings) decides, so the answer is at least stable and reproducible.
    /// - `insideApp` with no candidates: `.interface`. Chrome is everything that
    ///   is not a code or terminal surface, so "nothing matched" *is* the answer
    ///   rather than a failure.
    /// - `outsideApp`: fall back to the key window's focused surface, and to
    ///   `.interface` when there is none. Only the menu shortcuts can land here.
    public static func resolve(
        pointer: ZoomPointerLocation,
        focusedSurface: ZoomSurfaceKind?
    ) -> ZoomZone {
        switch pointer {
        case .outsideApp:
            return focusedSurface?.zone ?? .interface
        case .insideApp(let candidates):
            // `max(by:)` returns the *last* maximal element, which would make a
            // tie resolve to the last candidate in scan order; reduce explicitly
            // with a strict `>` so the first one wins, as documented.
            var winner: ZoomSurfaceCandidate?
            for candidate in candidates {
                if let current = winner, candidate.depth <= current.depth { continue }
                winner = candidate
            }
            return winner?.kind.zone ?? .interface
        }
    }
}
