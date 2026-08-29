import Foundation

/// Why a `WorkspaceEdit` did not become a plan — one named reason per refusal,
/// and every one of them fatal to the **whole** rename.
///
/// All-or-nothing is the point. A rename that applied to four files out of five
/// would leave a project that no longer compiles and no single step to undo,
/// which is strictly worse than a rename that did not happen: the user still has
/// the old name in front of them and can ask again. So nothing here is a warning
/// to skip a file over — each case aborts construction, the command beeps or
/// alerts, and every file stays byte-identical.
///
/// The reasons are separate cases rather than one string because they are not
/// equally surprising: `outsideRoot` and `notAFile` are a server answering about
/// something this editor deliberately does not touch, `unmappable` is a server
/// whose coordinates disagree with the text in hand, and `unreadable` is the
/// disk. Only the last two are worth putting a file name in front of a user, and
/// a caller cannot tell them apart from a rendered sentence.
public enum RenameRefusal: Error, Equatable, Sendable {
    /// A `WorkspaceEdit` document URI that is not a file URL — nothing this
    /// editor can open, let alone rewrite.
    case notAFile(uri: String)
    /// A file outside the opened project root. Compared canonically: a server
    /// answering `/private/tmp/…` about a project opened as `/tmp/…` is naming a
    /// file that *is* inside the root, and a lexical prefix test would refuse a
    /// legitimate rename on every such project.
    case outsideRoot(URL)
    /// The file's text could not be read, so its edits have no offsets.
    case unreadable(URL)
    /// A range whose LSP coordinates do not exist in the text this plan was
    /// built against — a line past the end, a character past its line's content,
    /// or an end before its start. `LSPPositionMap` would clamp each of those
    /// into a real range, which is right for a *jump* and wrong for a *write*:
    /// the clamp would silently move the edit onto text the server never meant.
    case unmappable(URL)
    /// Two edits in one file whose ranges overlap. There is no order in which
    /// both are correct, and applying them in either produces text no server
    /// asked for.
    case overlapping(URL)

    /// The file the refusal is about, where it is about one.
    public var fileURL: URL? {
        switch self {
        case .notAFile: return nil
        case .outsideRoot(let url), .unreadable(let url),
             .unmappable(let url), .overlapping(let url):
            return url
        }
    }

    /// A sentence for the one place a refusal is shown — the rename command's
    /// alert. Phrased as what happened, never as advice.
    public var reason: String {
        switch self {
        case .notAFile(let uri):
            return "The language server named a location that is not a file: \(uri)."
        case .outsideRoot(let url):
            return "The rename would change \(url.lastPathComponent), which is outside this project."
        case .unreadable(let url):
            return "\(url.lastPathComponent) could not be read."
        case .unmappable(let url):
            return "The language server's edit does not fit the current text of \(url.lastPathComponent)."
        case .overlapping(let url):
            return "The language server sent overlapping edits for \(url.lastPathComponent)."
        }
    }
}

/// One replacement inside one file, expressed in the editor's coordinates and
/// carrying the text the range held when the plan was built.
///
/// `expectedText` is the whole staleness story. A rename's request, its answer
/// and its application are three separate moments with awaits between them, and
/// in those moments a git operation, another editor or the user's own typing can
/// move the text under a range the server computed against something else.
/// Comparing the *document version* would only catch the cases a server bothered
/// to number; comparing the bytes the range currently holds catches every case,
/// including a server that sends no version at all — which is why the decoded
/// `version` is kept and never compared.
public struct RenameEdit: Equatable, Sendable {
    /// UTF-16 range in the file's text, in the coordinates of the text the plan
    /// was built against.
    public let range: NSRange
    /// What that range becomes.
    public let newText: String
    /// What that range held when the plan was built. See the type's note.
    public let expectedText: String

    public init(range: NSRange, newText: String, expectedText: String) {
        self.range = range
        self.newText = newText
        self.expectedText = expectedText
    }
}

/// Every edit one file receives, ascending and non-overlapping.
///
/// Ascending-and-non-overlapping is `SaveTransformPlan`'s shape and is required
/// for the same two reasons: it is what lets a text view apply the edits
/// back-to-front inside one editing bracket (one undoable step, one change
/// notification), and it is what makes the position remap expressible against
/// the original offsets.
public struct RenameFilePlan: Equatable, Sendable {
    /// The file, standardized — the spelling a caller writes and opens by.
    public let fileURL: URL
    /// The file's path below the project root, `/`-joined. What the alert and the
    /// pre-operation capture name it by.
    public let relativePath: String
    /// The edits, ascending by location and never overlapping.
    public let edits: [RenameEdit]

    public init(fileURL: URL, relativePath: String, edits: [RenameEdit]) {
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.edits = edits
    }

    /// Whether `text` still holds what every edit was computed against.
    ///
    /// A range reaching past the end of `text` fails here rather than trapping:
    /// this is asked about a buffer that may have been rewritten wholesale since
    /// the plan was made, and "the file shrank" is an ordinary staleness, not a
    /// programming error.
    public func holds(in text: String) -> Bool {
        let source = text as NSString
        return edits.allSatisfy { edit in
            guard edit.range.location >= 0,
                  NSMaxRange(edit.range) <= source.length else { return false }
            return source.substring(with: edit.range) == edit.expectedText
        }
    }

    /// The text this file becomes, plus the remap that keeps a caret, a selection
    /// and a scroll anchor sane — or `nil` when `text` is no longer what the plan
    /// was built against.
    ///
    /// A `SaveTransformPlan` rather than a type of its own, because it is
    /// literally the same thing: ascending non-overlapping replacements, the text
    /// they produce, and one arithmetic for moving positions through them. Going
    /// through it also means the displayed tab's application path is the one the
    /// app already has — `SaveTransformController` applies a plan through the live
    /// text view as one undoable step and falls back to
    /// `WorkspaceModel.replaceText(_:for:)` for a buffer no editor holds.
    public func applied(to text: String) -> SaveTransformPlan? {
        guard holds(in: text) else { return nil }
        let result = NSMutableString(string: text)
        // Back to front, so each edit's range is still expressed in coordinates
        // nothing before it has moved.
        for edit in edits.reversed() {
            result.replaceCharacters(in: edit.range, with: edit.newText)
        }
        return SaveTransformPlan(
            replacements: edits.map {
                IndentReplacement(range: $0.range, replacement: $0.newText)
            },
            text: result as String
        )
    }
}

/// Whether every file a plan touches still holds the text the plan was built
/// against.
///
/// Two cases and no count of them: the first mismatch aborts, because the answer
/// to "which files are stale" changes nothing a caller does. A rename either
/// applies whole or not at all, and the one file worth naming is the one that
/// made it impossible.
public enum RenameVerification: Equatable, Sendable {
    case verified
    /// The file whose text no longer matches — including a file whose text could
    /// not be read at all, which was readable when the plan was built and is
    /// therefore exactly as stale as one that changed.
    case stale(URL)

    public var isVerified: Bool { self == .verified }
}

/// A language server's `WorkspaceEdit`, turned into something this editor can
/// verify and apply — and nothing else.
///
/// **Pure.** It reads no file and writes none: the texts come in as a closure the
/// caller answers from the open buffers first and the disk second, and what comes
/// out is per-file replacements. That is what lets the whole rename decision be
/// unit-tested, and what keeps the disk writes in the one place that holds the
/// writer bracket.
///
/// The three moments are deliberately separate methods:
///
/// 1. `make(from:root:texts:)` — build, against the texts in hand *before* the
///    writer bracket is raised. Every refusal happens here, where nothing has
///    been captured and nothing suspended.
/// 2. `verify(against:)` — re-ask inside the bracket, after the Local History
///    capture, against the texts as they then are. This is the last moment
///    anything can abort.
/// 3. `RenameFilePlan.applied(to:)` — the bytes, per file, produced only once
///    verification passed.
///
/// Steps 1 and 3 both check `holds`, and that is not redundant: step 1's check is
/// against texts that may be minutes old by the time step 3 runs, and step 3 is
/// the one that must not write into a file that moved.
public struct RenameEditPlan: Equatable, Sendable {
    /// The files, ordered by their canonical path so one answer always produces
    /// one plan. `changes` arrives as an unordered map and `documentChanges` in
    /// whatever order the server chose; both must yield the same plan, or the
    /// same rename would capture, verify and write in two different orders on two
    /// runs.
    public let files: [RenameFilePlan]

    public init(files: [RenameFilePlan]) {
        self.files = files
    }

    /// Nothing to write. The command treats this exactly as it treats a server
    /// that refused — a plan that touches nothing must never raise the writer
    /// bracket.
    public var isEmpty: Bool { files.allSatisfy(\.edits.isEmpty) }

    /// Every file the plan touches, in plan order — what the pre-operation
    /// capture is handed as its targets.
    public var fileURLs: [URL] { files.map(\.fileURL) }

    /// The total number of replacements, for the dialog's own accounting.
    public var editCount: Int { files.reduce(0) { $0 + $1.edits.count } }

    /// Build the plan, or name the first thing that made it impossible.
    ///
    /// - Parameters:
    ///   - edit: the server's answer, already normalised across its two spellings
    ///     by `LSPWorkspaceEdit`.
    ///   - root: the opened project root. A file outside it is refused; nothing
    ///     this command does may rewrite a file the user did not open a project
    ///     for.
    ///   - texts: the current text of a file — the open buffer's where one exists,
    ///     the disk copy otherwise. `nil` refuses.
    ///
    /// One document may legitimately appear more than once (`documentChanges` is
    /// a list, not a map), so entries are grouped by canonical path first and the
    /// grouped edits sorted together: two entries whose edits interleave are one
    /// file's edits, and sorting them separately would produce a descending pair
    /// no back-to-front application can survive.
    public static func make(
        from edit: LSPWorkspaceEdit,
        root: URL,
        texts: (URL) -> String?
    ) -> Result<RenameEditPlan, RenameRefusal> {
        let rootComponents = CanonicalPath.canonical(root).pathComponents
        var order: [String] = []
        var grouped: [String: (url: URL, edits: [LSPTextEdit])] = [:]

        for document in edit.documents where !document.edits.isEmpty {
            guard let url = URL(string: document.uri), url.isFileURL else {
                return .failure(.notAFile(uri: document.uri))
            }
            let file = url.standardizedFileURL
            guard CanonicalPath.relativeComponents(
                of: CanonicalPath.canonical(file).pathComponents,
                under: rootComponents
            ) != nil else {
                return .failure(.outsideRoot(file))
            }
            let key = CanonicalPath.canonical(file).path
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = (file, document.edits)
            } else {
                grouped[key]?.edits.append(contentsOf: document.edits)
            }
        }

        var files: [RenameFilePlan] = []
        for key in order.sorted() {
            guard let entry = grouped[key] else { continue }
            guard let text = texts(entry.url) else {
                return .failure(.unreadable(entry.url))
            }
            switch filePlan(for: entry.url, edits: entry.edits, text: text, root: rootComponents) {
            case .success(let plan): files.append(plan)
            case .failure(let refusal): return .failure(refusal)
            }
        }
        return .success(RenameEditPlan(files: files))
    }

    /// Re-ask, inside the writer bracket, whether the world still matches the
    /// plan. `texts` answers from the open buffer where one exists and the disk
    /// otherwise — the same rule `make` was given, asked again at the last moment
    /// before anything is written.
    public func verify(against texts: (URL) -> String?) -> RenameVerification {
        for file in files {
            guard let text = texts(file.fileURL), file.holds(in: text) else {
                return .stale(file.fileURL)
            }
        }
        return .verified
    }

    // MARK: - Private

    private static func filePlan(
        for file: URL,
        edits: [LSPTextEdit],
        text: String,
        root: [String]
    ) -> Result<RenameFilePlan, RenameRefusal> {
        let source = text as NSString
        let lineStarts = LSPPositionMap.lineStarts(in: source)
        var mapped: [RenameEdit] = []

        for edit in edits {
            guard let range = bufferRange(
                for: edit.range, in: source, lineStarts: lineStarts
            ) else {
                return .failure(.unmappable(file))
            }
            mapped.append(
                RenameEdit(
                    range: range,
                    newText: edit.newText,
                    expectedText: source.substring(with: range)
                )
            )
        }

        mapped.sort { left, right in
            if left.range.location != right.range.location {
                return left.range.location < right.range.location
            }
            return left.range.length < right.range.length
        }
        for (previous, next) in zip(mapped, mapped.dropFirst())
        where NSMaxRange(previous.range) > next.range.location {
            return .failure(.overlapping(file))
        }
        // Two zero-length edits at one offset do not overlap by that test and are
        // still two answers to one question; a rename never inserts, so this can
        // only be a server contradicting itself.
        for (previous, next) in zip(mapped, mapped.dropFirst())
        where previous.range.length == 0 && next.range.length == 0
            && previous.range.location == next.range.location {
            return .failure(.overlapping(file))
        }

        let inside = CanonicalPath.relativeComponents(
            of: CanonicalPath.canonical(file).pathComponents,
            under: root
        )
        return .success(
            RenameFilePlan(
                fileURL: file,
                relativePath: inside?.joined(separator: "/") ?? file.lastPathComponent,
                edits: mapped
            )
        )
    }

    /// An LSP range as a buffer range, or `nil` when the coordinates do not exist
    /// in this text.
    ///
    /// `LSPPositionMap` clamps, on purpose and rightly: every other caller is
    /// navigating, and the nearest real position beats refusing to move. A write
    /// is the one case where the clamp is the bug, so the mapping is checked by
    /// round-tripping each offset back into a position — the clamp bit exactly
    /// when the position that comes back differs from the one that went in.
    private static func bufferRange(
        for range: LSPRange,
        in content: NSString,
        lineStarts: [Int]
    ) -> NSRange? {
        guard let start = exactOffset(for: range.start, in: content, lineStarts: lineStarts),
              let end = exactOffset(for: range.end, in: content, lineStarts: lineStarts),
              end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func exactOffset(
        for position: LSPPosition,
        in content: NSString,
        lineStarts: [Int]
    ) -> Int? {
        guard position.line >= 0, position.character >= 0 else { return nil }
        let offset = LSPPositionMap.offset(for: position, in: content, lineStarts: lineStarts)
        let roundTrip = LSPPositionMap.position(
            forOffset: offset, lineStarts: lineStarts, length: content.length
        )
        return roundTrip == position ? offset : nil
    }
}

// MARK: - Applying

/// What one rename actually did — the disk writes it performed itself, and the
/// buffer rewrites it is handing back for the editor to perform.
///
/// The split is not an implementation detail, it is the whole of decision 5. A
/// file no tab holds is *disk*: the engine writes it, and there is no undo for it
/// anywhere but Local History. A file a tab holds is a *buffer*: rewriting it on
/// disk behind an open editor would leave the tab showing the old text over new
/// bytes, so the engine writes nothing and the app rewrites the buffer instead —
/// which is also the only way the displayed tab can get the one undoable step it
/// gets. That application needs a text view, so it cannot happen in Core.
public struct RenameApplication: Equatable {
    /// One open buffer's rewrite: the file, and the ascending plan the editor
    /// applies to it.
    public struct BufferRewrite: Equatable {
        public let fileURL: URL
        public let plan: SaveTransformPlan

        public init(fileURL: URL, plan: SaveTransformPlan) {
            self.fileURL = fileURL
            self.plan = plan
        }
    }

    /// The buffers to rewrite, in plan order. The caller has not applied these
    /// yet — that is what it does next.
    public let bufferRewrites: [BufferRewrite]
    /// The files this call wrote to disk, in the order it wrote them.
    public let filesWritten: [URL]
    /// The file whose disk write threw, when one did. Everything in
    /// `filesWritten` landed; this one and anything after it did not.
    ///
    /// A rename is all-or-nothing *up to the first byte written* — every refusal
    /// and the whole staleness verification happen before that — and after it
    /// nothing can put the bytes back but the "Before Rename" revisions the
    /// bracket captured. So a failed write is reported rather than swallowed and
    /// rather than pretended to be an abort: the files that changed have changed.
    public let writeFailure: URL?

    public init(
        bufferRewrites: [BufferRewrite],
        filesWritten: [URL],
        writeFailure: URL? = nil
    ) {
        self.bufferRewrites = bufferRewrites
        self.filesWritten = filesWritten
        self.writeFailure = writeFailure
    }
}

/// The result of asking a plan to apply itself.
///
/// Two cases, because there are only two things the caller does: tell the user
/// which file moved and stop, or carry out the buffer half and resync. A stale
/// answer has written nothing at all.
public enum RenameApplyOutcome: Equatable {
    case applied(RenameApplication)
    /// The file whose text no longer matched. Nothing was written.
    case stale(URL)
}

public extension RenameEditPlan {
    /// Verify and apply, inside the caller's writer bracket.
    ///
    /// The one method in this file that touches the disk, and it is where the
    /// rename's atomicity lives: **every** file is read and verified before
    /// **any** file is written, so a rename that cannot complete leaves every
    /// byte on disk and in every buffer exactly as it was. The alternative —
    /// verifying each file as it is written — turns one stale file into a project
    /// half-renamed, which is the state this whole feature is built to avoid.
    ///
    /// - Parameters:
    ///   - bufferText: the text an open tab holds for a file, or `nil` when no tab
    ///     holds it. Asked before the disk for the same reason `verify(against:)`
    ///     is asked with it: a dirty buffer is the text the user is looking at, and
    ///     writing a server's edits into the disk copy under it would be a rename
    ///     of text nobody can see.
    ///   - fileService: the disk, for the files no tab holds.
    ///
    /// A file that cannot be *read* here is reported as `.stale`, not as a
    /// separate failure: it was readable when the plan was built, so whatever
    /// happened to it since is exactly the kind of change staleness exists to
    /// refuse — and the caller's answer ("this file moved, nothing was renamed")
    /// is the same one.
    func apply(
        bufferText: (URL) -> String?,
        fileService: FileServicing
    ) -> RenameApplyOutcome {
        var resolved: [(file: RenameFilePlan, text: String, isBuffer: Bool)] = []
        for file in files where !file.edits.isEmpty {
            if let buffered = bufferText(file.fileURL) {
                resolved.append((file, buffered, true))
            } else if let onDisk = try? fileService.read(url: file.fileURL) {
                resolved.append((file, onDisk, false))
            } else {
                return .stale(file.fileURL)
            }
        }

        // Every file, before any write. `applied(to:)` re-checks `holds` itself,
        // so the two passes below cannot disagree — but the check has to happen in
        // a pass of its own regardless, because the *first* file's write must not
        // happen until the *last* file's text has been vouched for.
        var rewrites: [RenameApplication.BufferRewrite] = []
        var pendingWrites: [(url: URL, text: String)] = []
        for entry in resolved {
            guard let applied = entry.file.applied(to: entry.text) else {
                return .stale(entry.file.fileURL)
            }
            if entry.isBuffer {
                rewrites.append(
                    RenameApplication.BufferRewrite(fileURL: entry.file.fileURL, plan: applied)
                )
            } else {
                pendingWrites.append((entry.file.fileURL, applied.text))
            }
        }

        var written: [URL] = []
        for pending in pendingWrites {
            do {
                try fileService.write(pending.text, to: pending.url)
            } catch {
                return .applied(
                    RenameApplication(
                        bufferRewrites: rewrites,
                        filesWritten: written,
                        writeFailure: pending.url
                    )
                )
            }
            written.append(pending.url)
        }
        return .applied(
            RenameApplication(bufferRewrites: rewrites, filesWritten: written)
        )
    }
}

// MARK: - The new name

/// What the rename dialog will accept, and why it refuses everything else.
///
/// In Core rather than in the dialog because it is a decision, not a widget: the
/// same two rules would have to be restated by any second surface that ever asks
/// for a new name, and a rule restated is a rule that drifts.
///
/// Both refusals are knowable while the user types, which is why they are
/// *reasons* rather than a failure after OK. Blank input is deliberately not one
/// of them — an empty field is incomplete input, not a mistake, and the dialog
/// disables OK for it without saying anything.
public enum RenameNameRule {
    /// Why `newName` cannot replace `oldName`, or `nil` when it can.
    ///
    /// The identifier rule is `IdentifierScanner.isIdentifier(_:)` — the very rule
    /// that decided what the caret was pointing at — so a name this accepts is one
    /// the editor can resolve back to a symbol. Anything else would produce a
    /// "rename" whose result could never be renamed again.
    public static func rejection(of newName: String, replacing oldName: String) -> String? {
        guard !newName.isEmpty else { return nil }
        guard IdentifierScanner.isIdentifier(newName) else {
            return "A symbol name must be a single identifier."
        }
        guard newName != oldName else {
            return "The new name must differ from the current one."
        }
        return nil
    }
}
