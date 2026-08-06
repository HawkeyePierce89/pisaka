import Foundation

/// One tab recorded in a persisted session.
///
/// Deliberately a **flat struct with two optional fields** rather than an enum
/// with associated values (`.file(path:)` / `.untitled(text:)`), even though the
/// two factories below make it read like one. The synthesized `Codable` for an
/// enum encodes the case *name* and throws `DataCorrupted` on an unknown one, so
/// a session written by a future version that adds a third kind of tab would
/// fail to decode **wholesale** — one unknown record costing the user every other
/// tab. A keyed struct decoder skips keys it does not know, which is exactly the
/// forward compatibility wanted here.
///
/// The price is that the decoder is **permissive**: a record carrying neither
/// `path` nor `text` decodes successfully, as a `SessionTab` with both fields
/// `nil`. That is not an oversight — it *is* the future-version tab (a new kind
/// whose fields this build has no property for, so they are skipped and nothing
/// is left). Deciding what such a record means is not the decoder's job: it
/// belongs to restore (`WorkspaceModel.restoreSession(_:)`), the only place that
/// knows how to turn a record into a tab, and which skips it exactly as it skips
/// a file it cannot read.
public struct SessionTab: Codable, Equatable {
    /// The file's path, spelled exactly as the tab spells it (see
    /// `EditorSession.snapshot` — verbatim, never canonicalized). `nil` for an
    /// Untitled buffer.
    public var path: String?

    /// The Untitled buffer's contents. `nil` for a titled file — a dirty titled
    /// file's *contents* are deliberately not persisted (see `EditorSession`).
    public var text: String?

    public init(path: String? = nil, text: String? = nil) {
        self.path = path
        self.text = text
    }

    /// A tab for the file at `path`.
    public static func file(path: String) -> SessionTab {
        SessionTab(path: path, text: nil)
    }

    /// A tab for an Untitled buffer carrying `text`.
    public static func untitled(text: String) -> SessionTab {
        SessionTab(path: nil, text: text)
    }
}

/// A persisted editor session: the opened folder, the open tabs in order, and
/// which one was selected.
///
/// Written continuously (debounced) rather than only on exit, so it survives a
/// crash or a force-quit as well as an ordinary quit. Three limits are
/// deliberate:
///
/// 1. **The contents of dirty *titled* files are not persisted** — only their
///    paths. Their text has somewhere to live (the file itself), and autosave
///    already puts it there: on an ordinary quit `flushNow` writes every dirty
///    titled buffer before the session snapshot is taken, and on a crash at most
///    one autosave window (~2 s of typing) is lost — the same exposure the editor
///    already has without any session restore. An Untitled buffer is the opposite
///    case: autosave skips it because it has nowhere to write, so its text is
///    stored here or lost for good.
/// 2. **Untitled text is not size-capped.** The session goes into `UserDefaults`,
///    so a pathologically large scratch buffer is written on every debounce. If
///    that ever bites, move the blob to Application Support — the model does not
///    change, only `SessionStore`'s backing store.
/// 3. **One session, under one key, with no per-window identity.** That is exact
///    today rather than a limitation: the app is single-window and its
///    `WorkspaceModel` is a single `@StateObject` on the `App`, shared by every
///    scene, so there is only ever one workspace state to snapshot. It becomes a
///    limitation the moment genuinely independent windows exist — two of them
///    would write their own snapshots under this one key, last writer winning, and
///    merging their tabs would need a per-window identity this model does not
///    carry.
public struct EditorSession: Codable, Equatable {
    /// The opened project folder's path, or `nil` when no folder was open.
    public var folderPath: String?

    /// The open tabs, in `openFiles` order.
    public var tabs: [SessionTab]

    /// Index into `tabs` of the selected tab, or `nil` when nothing was selected
    /// (or the selected tab was not stored — an empty Untitled buffer).
    public var selectedIndex: Int?

    public init(folderPath: String? = nil, tabs: [SessionTab] = [], selectedIndex: Int? = nil) {
        self.folderPath = folderPath
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }

    /// Whether this session records nothing worth restoring.
    public var isEmpty: Bool {
        folderPath == nil && tabs.isEmpty
    }

    /// Build a session from the live workspace state.
    ///
    /// Pure: the whole decision — which buffers are worth storing, and where the
    /// selection lands once some were dropped — is expressed here so it is unit
    /// tested, while the view layer only decides *when* to call it.
    ///
    /// Rules. Tabs keep their `openFiles` order. A titled file contributes its
    /// path; an Untitled buffer contributes its text unless that text is
    /// **literally empty** (no trimming — a buffer holding only whitespace is
    /// something the user typed and gets restored), in which case the record is
    /// dropped: an empty scratch buffer carries nothing worth bringing back, and
    /// storing it would mean a launch handing out a tab whose only content is the
    /// fact that one was open.
    /// `selectedIndex` is an index into the records actually **stored**, so it
    /// shifts past every dropped one, and is `nil` when nothing is selected or
    /// when the selected buffer's own record was dropped.
    ///
    /// **Paths are stored exactly as the tab spells them** — no `CanonicalPath`,
    /// no symlink resolution. The stored spelling is the one the user opened,
    /// which is what keeps the restored tab, the project tree and the breadcrumb
    /// agreeing after a restart (`DisplayPath` prefers the lexical spelling for
    /// the same reason). Canonicalization is a *matching* rule, so it lives on the
    /// read side, where restore applies it for dedup — the same asymmetry
    /// `WorkspaceModel.open(url:)` already has, storing the url as given while
    /// matching canonically.
    public static func snapshot(
        openFiles: [OpenFile],
        selectedID: UUID?,
        projectRoot: URL?
    ) -> EditorSession {
        var tabs: [SessionTab] = []
        var selectedIndex: Int?
        for file in openFiles {
            let record: SessionTab
            if let url = file.url {
                record = .file(path: url.path)
            } else if !file.text.isEmpty {
                record = .untitled(text: file.text)
            } else {
                continue
            }
            if file.id == selectedID {
                selectedIndex = tabs.count
            }
            tabs.append(record)
        }
        return EditorSession(
            folderPath: projectRoot?.path,
            tabs: tabs,
            selectedIndex: selectedIndex
        )
    }
}

/// Persists the last `EditorSession` through an injected `UserDefaults`, following
/// `BookmarkStore`'s shape exactly: Foundation-only, one property-list blob under a
/// stable key, `UserDefaults` injected so tests run against an isolated suite.
///
/// Everything that can go wrong reading the blob resolves to `nil` rather than
/// trapping — a missing key (no session was ever written), a value of the wrong
/// type, a truncated or hand-edited plist, a plist whose shape this version cannot
/// decode. There is nothing better to do with a corrupt session than start from a
/// blank slate, and a launch is precisely where a trap would be least recoverable.
/// Forward compatibility inside a *well-formed* blob is `SessionTab`'s job (see
/// there): unknown keys are skipped by the synthesized keyed decoder, so a session
/// written by a future version still loads with everything this build understands.
///
/// An **empty session is an ordinary value** — stored, read back and returned like
/// any other. It must not be conflated with "nothing stored": a user who closed
/// every tab and quit has to come back to an empty editor, not to the session
/// before last.
public final class SessionStore {
    /// Stable persisted key — must not be renamed.
    public enum Keys {
        public static let lastSession = "session.lastSession"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The persisted session, or `nil` when none was ever written or the stored
    /// blob cannot be decoded.
    public func load() -> EditorSession? {
        guard
            let data = defaults.data(forKey: Keys.lastSession),
            let decoded = try? PropertyListDecoder().decode(EditorSession.self, from: data)
        else { return nil }
        return decoded
    }

    /// Persist `session`, replacing whatever was stored. A failure to encode is
    /// swallowed, leaving the previous session in place — the same `try?` posture
    /// as `BookmarkStore`.
    public func save(_ session: EditorSession) {
        guard let data = try? PropertyListEncoder().encode(session) else { return }
        defaults.set(data, forKey: Keys.lastSession)
    }

    /// Drop the stored session, so the next `load()` reports `nil`.
    public func clear() {
        defaults.removeObject(forKey: Keys.lastSession)
    }
}
