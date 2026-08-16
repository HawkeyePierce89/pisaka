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

/// Every project's persisted session, keyed by its folder and ordered
/// most-recently-opened first.
///
/// **Head is the pointer.** `entries[0]` is the last opened project, so
/// `lastOpened` is a *derivation* rather than a stored field. That is the whole
/// reason the order is load-bearing: a separate `lastOpenedFolder` field could
/// name a folder no entry carries, and "the pointer points at a session that is
/// not stored" would be a state someone has to handle. Here it is
/// unrepresentable.
///
/// **Keying follows store-as-spelled / match-canonically**, the rule
/// `EditorSession.snapshot` and `WorkspaceModel.open(url:)` already share: an
/// entry records the folder path *verbatim*, exactly as the user spelled it, and
/// every lookup compares through `CanonicalPath.canonical(_:)`. So `/tmp` and
/// `/private/tmp`, a trailing slash and a `.`/`..` detour all land on one entry
/// instead of quietly accumulating one session per spelling. A `nil`
/// `folderPath` is a key like any other — the no-folder workspace — and matches
/// only itself, never a real folder.
///
/// **Retention is capped by entry count, never by byte size**
/// (`maxStoredProjects`, the same number and rationale as
/// `ScopedFileAccess.updatedRecents`' recents cap), evicting from the tail. The
/// count rule is the point, not a simplification: entries are independent
/// values, so one project's pathologically large untitled buffer (limit 2 on
/// `EditorSession`) cannot evict *another* project's session, and nothing one
/// project stores changes what another decodes to. The only shared failure mode
/// left is an unreadable *whole* blob, which resolves to a blank slate exactly
/// as the single blob did before. If the total size ever bites, the escape hatch
/// is the one already recorded on `EditorSession`: move the backing store to
/// Application Support — this model does not change.
public struct SessionCatalog: Codable, Equatable {
    /// One project's stored session, under the folder path spelled verbatim.
    public struct Entry: Codable, Equatable {
        /// The project folder's path as the user spelled it, or `nil` for the
        /// no-folder workspace. Matched canonically, never stored canonically.
        public var folderPath: String?

        /// That project's session.
        public var session: EditorSession

        public init(folderPath: String?, session: EditorSession) {
            self.folderPath = folderPath
            self.session = session
        }
    }

    /// How many projects are remembered before the least recently opened is
    /// dropped. Counted in *entries*, deliberately — see the type's note.
    public static let maxStoredProjects = 20

    /// The stored projects, most recently opened first.
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// The last opened project's session, or `nil` when nothing was ever stored.
    ///
    /// This *is* the launch-restore pointer: the head of the MRU order, not a
    /// field that could disagree with it.
    public var lastOpened: EditorSession? {
        entries.first?.session
    }

    /// The session stored for `folder`, matched canonically, or `nil` when that
    /// project has none. `nil` asks for the no-folder workspace's session and
    /// matches only the `nil`-key entry.
    public func session(forFolder folder: URL?) -> EditorSession? {
        let wanted = Self.key(for: folder)
        return entries.first { Self.key(forPath: $0.folderPath) == wanted }?.session
    }

    /// Upsert `session` under its own `folderPath` and promote it to the head.
    ///
    /// The existing entry for that folder — matched canonically, so any spelling
    /// of it — is *replaced*, adopting the incoming verbatim spelling: the
    /// user's latest spelling is the one worth showing back. Absent, it is
    /// inserted. Then everything past `limit` is dropped from the tail, so the
    /// entry just stored can never be the one evicted (`limit` is clamped to at
    /// least one for that reason).
    public mutating func store(_ session: EditorSession, limit: Int = maxStoredProjects) {
        let key = Self.key(forPath: session.folderPath)
        entries.removeAll { Self.key(forPath: $0.folderPath) == key }
        entries.insert(Entry(folderPath: session.folderPath, session: session), at: 0)
        let cap = max(1, limit)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
    }

    /// The one-entry catalog a legacy single-blob session becomes: its own
    /// `folderPath` (possibly `nil`) is the key, and it is the head — which is
    /// what keeps launch restore finding exactly the session it found before.
    public static func migrating(_ legacy: EditorSession) -> SessionCatalog {
        SessionCatalog(entries: [Entry(folderPath: legacy.folderPath, session: legacy)])
    }

    /// The match key: `CanonicalPath.canonical(_:).path` — the *path*, not the
    /// url, which is the same key `SymbolIndex` and `ProjectSearchModel` use and
    /// is load-bearing here. Two urls for one directory can differ by a trailing
    /// slash (`file:///p/root/` vs. `file:///p/root`) and compare unequal as
    /// urls while naming the same folder; their `.path`s do not.
    private static func key(for folder: URL?) -> String? {
        folder.map { CanonicalPath.canonical($0).path }
    }

    private static func key(forPath path: String?) -> String? {
        key(for: path.map { URL(fileURLWithPath: $0) })
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
