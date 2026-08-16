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
///    so a pathologically large scratch buffer is written on every debounce —
///    and since the blob is now the whole `SessionCatalog`, one write decodes and
///    re-encodes *every* remembered project, not just the current one, making the
///    cost proportional to the summed scratch text of up to `maxStoredProjects`
///    entries. `SessionController`'s equal-snapshot guard keeps that off the
///    steady state (an unchanged session is not rewritten), so it is only paid
///    while the session actually keeps changing. If it ever bites, the escape
///    hatch is unchanged: move the blob to Application Support, or key each
///    project separately — the model does not change, only `SessionStore`'s
///    backing store.
/// 3. **One session per project, with no per-window identity.** The project half
///    is `SessionCatalog`: one entry per folder, keyed by that folder, so opening
///    a different project no longer overwrites the one you left. The window half
///    is exact today rather than a limitation: the app is single-window and its
///    `WorkspaceModel` is a single `@StateObject` on the `App`, shared by every
///    scene, so there is only ever one workspace state to snapshot. It becomes a
///    limitation the moment genuinely independent windows exist — two of them on
///    the *same* project would write their own snapshots under that project's one
///    key, last writer winning, and merging their tabs would need a per-window
///    identity this model does not carry.
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

    /// The session to **store** for a project whose tabs were applied on top of
    /// tabs that were already open — `incoming` merged onto `carried`, in the
    /// order and with the selection `WorkspaceModel.restoreSession(_:)` leaves
    /// behind. `carried` contributes only its tabs; the identity of the result is
    /// `incoming`'s `folderPath`.
    ///
    /// This exists for exactly one caller — the **first Open Folder of a run**,
    /// where the outgoing workspace has no folder and its tabs travel *into* the
    /// project rather than being force-closed (see `WorkspaceModel.replaceSession`
    /// for the other, replacing case). What makes it load-bearing rather than a
    /// convenience is the store-vs-live invariant the switch rests on: **the
    /// session filed for the incoming project must be a superset of what the live
    /// model then holds.** The app seeds `SessionController`'s "already written"
    /// marker with the post-swap live snapshot so a restore that silently skipped
    /// records cannot be persisted over the recorded session — and that marker
    /// suppresses every later equal write, the quit-time flush included. Filing
    /// the *unmerged* `incoming` there would therefore make the carried tabs
    /// unwritable for the rest of the run: the pre-folder Untitled buffer would be
    /// on screen, absent from the stored session, and gone at the next launch.
    ///
    /// The selection mirrors `restoreSession`'s own rule: anything restored takes
    /// the selection, at `incoming`'s recorded index or — when that index is
    /// absent or out of range — its last tab; an `incoming` with no tabs at all
    /// leaves `carried`'s selection standing.
    public static func merging(_ incoming: EditorSession, onto carried: EditorSession) -> EditorSession {
        guard !incoming.tabs.isEmpty else {
            return EditorSession(
                folderPath: incoming.folderPath,
                tabs: carried.tabs,
                selectedIndex: carried.selectedIndex
            )
        }
        let landing = incoming.selectedIndex.flatMap { incoming.tabs.indices.contains($0) ? $0 : nil }
            ?? (incoming.tabs.count - 1)
        return EditorSession(
            folderPath: incoming.folderPath,
            tabs: carried.tabs + incoming.tabs,
            selectedIndex: carried.tabs.count + landing
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
    /// How many projects are remembered before the least recently opened is
    /// dropped. Counted in *entries*, deliberately — see the type's note.
    public static let maxStoredProjects = 20

    /// The stored projects' sessions, most recently opened first.
    ///
    /// **A session is its own key**: `EditorSession.folderPath` already records
    /// the folder verbatim, so no key is stored beside it. That is the `lastOpened`
    /// reasoning one level down — a key field naming a *different* folder than the
    /// session next to it would be a state someone has to handle (a lookup for
    /// `/a` handing back a session whose own path is `/b`, which the next
    /// `store(_:)` then files under `/b`, orphaning `/a`). Here it is
    /// unrepresentable.
    public var entries: [EditorSession]

    public init(entries: [EditorSession] = []) {
        self.entries = entries
    }

    /// The last opened project's session, or `nil` when nothing was ever stored.
    ///
    /// This *is* the launch-restore pointer: the head of the MRU order, not a
    /// field that could disagree with it.
    public var lastOpened: EditorSession? {
        entries.first
    }

    /// The session stored for `folder`, matched canonically, or `nil` when that
    /// project has none. `nil` asks for the no-folder workspace's session and
    /// matches only the `nil`-key entry.
    public func session(forFolder folder: URL?) -> EditorSession? {
        let wanted = Self.key(for: folder)
        return entries.first { Self.key(forPath: $0.folderPath) == wanted }
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
        entries.insert(session, at: 0)
        let cap = max(1, limit)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
    }

    /// The one-entry catalog a legacy single-blob session becomes: its own
    /// `folderPath` (possibly `nil`) is the key, and it is the head — which is
    /// what keeps launch restore finding exactly the session it found before.
    public static func migrating(_ legacy: EditorSession) -> SessionCatalog {
        SessionCatalog(entries: [legacy])
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

/// Persists every project's `EditorSession` through an injected `UserDefaults`,
/// following `BookmarkStore`'s shape exactly: Foundation-only, one property-list
/// blob under a stable key, `UserDefaults` injected so tests run against an
/// isolated suite. The blob is a `SessionCatalog`, so the store is *keyed* — one
/// session per project folder, MRU-ordered, its head the launch pointer.
///
/// Everything that can go wrong reading the blob resolves to "nothing stored"
/// rather than trapping — a missing key (nothing was ever written), a value of
/// the wrong type, a truncated or hand-edited plist, a plist whose shape this
/// version cannot decode. There is nothing better to do with a corrupt catalog
/// than start from a blank slate, and a launch is precisely where a trap would be
/// least recoverable. Forward compatibility inside a *well-formed* blob is
/// `SessionTab`'s job (see there): unknown keys are skipped by the synthesized
/// keyed decoder, so a session written by a future version still loads with
/// everything this build understands.
///
/// **Migration.** `Keys.lastSession` — the single blob this store wrote before
/// sessions became per-project — is read **only when `Keys.projectSessions` is
/// absent**, and seeds a one-entry catalog whose key is that blob's own
/// `folderPath` (possibly `nil`) and which is therefore also the head, so the
/// first launch after the upgrade restores exactly what the last launch would
/// have. Once the new key exists the legacy one is ignored *even if the new blob
/// is unreadable* — garbage under the new key means something wrote it, and
/// resurrecting a stale session at that point would be worse than a blank slate.
/// The legacy key is never written again and deliberately **not deleted**:
/// deleting buys nothing, and keeping it lets a downgrade still restore.
///
/// An **empty session is an ordinary value** — stored, read back and returned like
/// any other. It must not be conflated with "nothing stored": a user who closed
/// every tab and quit has to come back to an empty editor, not to the session
/// before last.
public final class SessionStore {
    /// Stable persisted keys — neither may ever be renamed. `lastSession` is the
    /// pre-catalog single blob, read for migration only (see the type's note);
    /// `projectSessions` holds the `SessionCatalog`.
    public enum Keys {
        public static let lastSession = "session.lastSession"
        public static let projectSessions = "session.projects"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last opened project's session — the catalog's head — or `nil` when
    /// nothing was ever written. This is what launch restore follows.
    public func loadLastOpened() -> EditorSession? {
        catalog().lastOpened
    }

    /// The session stored for `folder`, matched canonically (`nil` asks for the
    /// no-folder workspace's), or `nil` when that project has none — which is
    /// what a folder being opened for the first time looks like.
    public func session(forFolder folder: URL?) -> EditorSession? {
        catalog().session(forFolder: folder)
    }

    /// Upsert `session` into the catalog under its own `folderPath`, promoting it
    /// to the head and applying the retention cap.
    ///
    /// The signature is unchanged from the single-blob store on purpose: the
    /// snapshot already names the project it belongs to, so the debounced writer
    /// (`SessionController`) needs to know nothing about the keying. A failure to
    /// encode is swallowed, leaving the previous blob — every other project's
    /// session included — in place, the same `try?` posture as `BookmarkStore`.
    public func save(_ session: EditorSession) {
        var catalog = catalog()
        catalog.store(session)
        guard let data = try? PropertyListEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: Keys.projectSessions)
    }

    /// Drop every stored session, so the next read reports `nil`. Removes the
    /// legacy key too — otherwise clearing would migrate the pre-upgrade blob
    /// back in on the very next read.
    public func clear() {
        defaults.removeObject(forKey: Keys.projectSessions)
        defaults.removeObject(forKey: Keys.lastSession)
    }

    /// The stored catalog: the new blob when its key is present, the migrated
    /// legacy blob when it is not, an empty catalog otherwise. Presence is tested
    /// on the *object*, not on `data(forKey:)`, so a wrong-typed value under the
    /// new key still counts as written and does not fall back to the legacy one.
    private func catalog() -> SessionCatalog {
        if defaults.object(forKey: Keys.projectSessions) != nil {
            guard
                let data = defaults.data(forKey: Keys.projectSessions),
                let decoded = try? PropertyListDecoder().decode(SessionCatalog.self, from: data)
            else { return SessionCatalog() }
            return decoded
        }
        guard
            let legacyData = defaults.data(forKey: Keys.lastSession),
            let legacy = try? PropertyListDecoder().decode(EditorSession.self, from: legacyData)
        else { return SessionCatalog() }
        return SessionCatalog.migrating(legacy)
    }
}
