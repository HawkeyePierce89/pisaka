import Foundation

/// The LSP message bodies phase 2a actually uses — and deliberately no more.
///
/// One layer above `LSPMessage`, which knows only that a message is a request, a
/// notification or a response: this file says what `textDocument/definition`
/// asks and what a `CompletionItem` carries. It is still Foundation-only value
/// types, so every shape is decodable in a test from a recorded transcript
/// (`Tests/PisakaCoreTests/Fixtures/LSP/`) without a server ever being spawned.
///
/// Two rules run through all of it.
///
/// **Decode leniently, encode exactly.** A server is a program someone else
/// ships: it may answer `textDocument/definition` with a `Location`, an array of
/// them, an array of `LocationLink`s or `null`, and it may attach members no
/// version of the spec lists. Anything we might *receive* therefore tolerates
/// every legal spelling and ignores the rest, while anything we *send* is written
/// one way only, because a request the server cannot parse is a request that
/// never gets answered.
///
/// **Open sets stay open.** `CompletionItemKind` and friends are
/// `RawRepresentable` structs rather than enums: an unknown kind must round-trip
/// (it is echoed back verbatim on `completionItem/resolve`), and a `switch` over
/// a closed enum would make a newer server's item fail to decode at all —
/// dropping a perfectly good completion over a number we did not recognise.
///
/// Positions here are *LSP* positions (zero-based line, UTF-16 code units within
/// the line). Turning one into a buffer offset — the only coordinate the editor
/// understands — is `LSPPositionMap`'s job, and D1's separator rule lives there.

// MARK: - Method names

/// The methods this phase speaks, spelled once.
///
/// Constants rather than a string at each call site: a typo in a method name is
/// answered with `MethodNotFound` at runtime and by nothing at all at compile
/// time, and these same strings are matched against in `LSPSession`'s dispatch.
public enum LSPMethod {
    public static let initialize = "initialize"
    public static let initialized = "initialized"
    public static let shutdown = "shutdown"
    public static let exit = "exit"
    public static let cancelRequest = "$/cancelRequest"

    public static let didOpen = "textDocument/didOpen"
    public static let didChange = "textDocument/didChange"
    public static let didClose = "textDocument/didClose"

    public static let definition = "textDocument/definition"
    public static let completion = "textDocument/completion"
    public static let resolveCompletionItem = "completionItem/resolve"

    // Server-initiated, answered by `LSPSession` (task 3).
    public static let registerCapability = "client/registerCapability"
    public static let unregisterCapability = "client/unregisterCapability"
    public static let workspaceConfiguration = "workspace/configuration"
}

// MARK: - Geometry

/// A zero-based LSP position: `line` counted with LSP's separators, `character`
/// in UTF-16 code units within that line (`positionEncoding: utf-16`, which the
/// client advertises explicitly rather than relying on it being the default).
public struct LSPPosition: Equatable, Hashable, Sendable, Codable, Comparable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static func < (lhs: LSPPosition, rhs: LSPPosition) -> Bool {
        lhs.line == rhs.line ? lhs.character < rhs.character : lhs.line < rhs.line
    }
}

/// A half-open range between two positions.
public struct LSPRange: Equatable, Hashable, Sendable, Codable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    /// A zero-length range — what a server sends for "the declaration is *here*",
    /// which is most of the recorded `textDocument/definition` answers.
    public init(at position: LSPPosition) {
        self.init(start: position, end: position)
    }

    public var isEmpty: Bool { start == end }
}

/// A place in a document. `uri` is kept as the string the server wrote: turning
/// it into a `URL` is the provider's job, and a URI we cannot parse must survive
/// long enough to be dropped deliberately rather than break the whole decode.
public struct LSPLocation: Equatable, Hashable, Sendable, Codable {
    public var uri: String
    public var range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// The richer definition answer: the same target, plus the span the *question*
/// covered and the target's own identifier range.
public struct LSPLocationLink: Equatable, Hashable, Sendable, Codable {
    /// The range in the *requesting* document the link originates from.
    public var originSelectionRange: LSPRange?
    public var targetUri: String
    /// The whole declaration.
    public var targetRange: LSPRange
    /// The declaration's name, which is where a jump should actually land.
    public var targetSelectionRange: LSPRange

    public init(
        originSelectionRange: LSPRange? = nil,
        targetUri: String,
        targetRange: LSPRange,
        targetSelectionRange: LSPRange
    ) {
        self.originSelectionRange = originSelectionRange
        self.targetUri = targetUri
        self.targetRange = targetRange
        self.targetSelectionRange = targetSelectionRange
    }
}

// MARK: - Documents

public struct LSPTextDocumentIdentifier: Equatable, Hashable, Sendable, Codable {
    public var uri: String
    public init(uri: String) { self.uri = uri }
}

public struct LSPVersionedTextDocumentIdentifier: Equatable, Hashable, Sendable, Codable {
    public var uri: String
    public var version: Int

    public init(uri: String, version: Int) {
        self.uri = uri
        self.version = version
    }
}

public struct LSPTextDocumentItem: Equatable, Hashable, Sendable, Codable {
    public var uri: String
    public var languageId: String
    public var version: Int
    public var text: String

    public init(uri: String, languageId: String, version: Int, text: String) {
        self.uri = uri
        self.languageId = languageId
        self.version = version
        self.text = text
    }
}

public struct LSPDidOpenTextDocumentParams: Equatable, Hashable, Sendable, Codable {
    public var textDocument: LSPTextDocumentItem
    public init(textDocument: LSPTextDocumentItem) { self.textDocument = textDocument }
}

/// One entry of `contentChanges`.
///
/// Only the whole-document spelling is ever *sent* (D2: `TextDocumentSyncKind`
/// `.full`, so no `range` member), but `range` is decodable so a transcript of
/// an incremental client round-trips through these types unchanged.
public struct LSPTextDocumentContentChangeEvent: Equatable, Hashable, Sendable, Codable {
    public var range: LSPRange?
    public var text: String

    public init(text: String) {
        self.range = nil
        self.text = text
    }

    public init(range: LSPRange?, text: String) {
        self.range = range
        self.text = text
    }
}

public struct LSPDidChangeTextDocumentParams: Equatable, Hashable, Sendable, Codable {
    public var textDocument: LSPVersionedTextDocumentIdentifier
    public var contentChanges: [LSPTextDocumentContentChangeEvent]

    public init(
        textDocument: LSPVersionedTextDocumentIdentifier,
        contentChanges: [LSPTextDocumentContentChangeEvent]
    ) {
        self.textDocument = textDocument
        self.contentChanges = contentChanges
    }

    /// The only spelling this client sends: replace the document with `text`.
    public init(uri: String, version: Int, fullText text: String) {
        self.init(
            textDocument: LSPVersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: [LSPTextDocumentContentChangeEvent(text: text)]
        )
    }
}

public struct LSPDidCloseTextDocumentParams: Equatable, Hashable, Sendable, Codable {
    public var textDocument: LSPTextDocumentIdentifier

    public init(textDocument: LSPTextDocumentIdentifier) { self.textDocument = textDocument }
    public init(uri: String) { self.init(textDocument: LSPTextDocumentIdentifier(uri: uri)) }
}

/// The shared shape of `textDocument/definition` (and of completion, which adds
/// a context).
public struct LSPTextDocumentPositionParams: Equatable, Hashable, Sendable, Codable {
    public var textDocument: LSPTextDocumentIdentifier
    public var position: LSPPosition

    public init(textDocument: LSPTextDocumentIdentifier, position: LSPPosition) {
        self.textDocument = textDocument
        self.position = position
    }

    public init(uri: String, position: LSPPosition) {
        self.init(textDocument: LSPTextDocumentIdentifier(uri: uri), position: position)
    }
}

// MARK: - Definition

/// One place `textDocument/definition` says the caret could jump to, normalised
/// across the three shapes a server may answer in.
///
/// `selectionRange` is the identifier's own range and is present only when the
/// server sent a `LocationLink`; `range` is whatever it gave — a whole
/// declaration for a link, the (usually empty) target range for a plain
/// `Location`. The provider jumps to `selectionRange ?? range`, so the richer
/// answer lands on the name and the plainer one still lands somewhere sensible.
public struct LSPDefinitionTarget: Equatable, Hashable, Sendable {
    public var uri: String
    public var range: LSPRange
    public var selectionRange: LSPRange?
    /// The span in the *asking* document this answer covers, when the server
    /// said so. Carried for completeness; nothing in phase 2a reads it.
    public var originSelectionRange: LSPRange?

    public init(
        uri: String,
        range: LSPRange,
        selectionRange: LSPRange? = nil,
        originSelectionRange: LSPRange? = nil
    ) {
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
        self.originSelectionRange = originSelectionRange
    }

    public init(location: LSPLocation) {
        self.init(uri: location.uri, range: location.range)
    }

    public init(link: LSPLocationLink) {
        self.init(
            uri: link.targetUri,
            range: link.targetRange,
            selectionRange: link.targetSelectionRange,
            originSelectionRange: link.originSelectionRange
        )
    }

    /// Where a jump should actually land.
    public var jumpRange: LSPRange { selectionRange ?? range }
}

/// The whole `textDocument/definition` result, whichever way it was spelled:
/// `null`, one `Location`, `Location[]`, or `LocationLink[]`.
///
/// A decode-only type. Each alternative is tried in turn and the *first* that
/// succeeds wins, which is unambiguous here because the four shapes are
/// distinguishable by JSON structure alone (null / object with `uri` / array of
/// those / array of objects with `targetUri`). An empty array decodes to no
/// targets, which is the same answer as `null` and is treated as such by
/// everything downstream.
public struct LSPDefinitionResponse: Equatable, Hashable, Sendable, Decodable {
    public var targets: [LSPDefinitionTarget]

    public init(targets: [LSPDefinitionTarget]) { self.targets = targets }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            targets = []
        } else if let links = try? container.decode([LSPLocationLink].self), !links.isEmpty {
            targets = links.map(LSPDefinitionTarget.init(link:))
        } else if let locations = try? container.decode([LSPLocation].self) {
            targets = locations.map(LSPDefinitionTarget.init(location:))
        } else if let location = try? container.decode(LSPLocation.self) {
            targets = [LSPDefinitionTarget(location: location)]
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not a Location, Location[], LocationLink[] or null"
            )
        }
    }

    public var isEmpty: Bool { targets.isEmpty }
}

// MARK: - Completion

/// LSP's `CompletionItemKind`. An open set (see the file comment) with the
/// spec's 1…25 named.
public struct LSPCompletionItemKind: RawRepresentable, Equatable, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let text = LSPCompletionItemKind(rawValue: 1)
    public static let method = LSPCompletionItemKind(rawValue: 2)
    public static let function = LSPCompletionItemKind(rawValue: 3)
    public static let constructor = LSPCompletionItemKind(rawValue: 4)
    public static let field = LSPCompletionItemKind(rawValue: 5)
    public static let variable = LSPCompletionItemKind(rawValue: 6)
    public static let `class` = LSPCompletionItemKind(rawValue: 7)
    public static let interface = LSPCompletionItemKind(rawValue: 8)
    public static let module = LSPCompletionItemKind(rawValue: 9)
    public static let property = LSPCompletionItemKind(rawValue: 10)
    public static let unit = LSPCompletionItemKind(rawValue: 11)
    public static let value = LSPCompletionItemKind(rawValue: 12)
    public static let `enum` = LSPCompletionItemKind(rawValue: 13)
    public static let keyword = LSPCompletionItemKind(rawValue: 14)
    public static let snippet = LSPCompletionItemKind(rawValue: 15)
    public static let color = LSPCompletionItemKind(rawValue: 16)
    public static let file = LSPCompletionItemKind(rawValue: 17)
    public static let reference = LSPCompletionItemKind(rawValue: 18)
    public static let folder = LSPCompletionItemKind(rawValue: 19)
    public static let enumMember = LSPCompletionItemKind(rawValue: 20)
    public static let constant = LSPCompletionItemKind(rawValue: 21)
    public static let `struct` = LSPCompletionItemKind(rawValue: 22)
    public static let event = LSPCompletionItemKind(rawValue: 23)
    public static let `operator` = LSPCompletionItemKind(rawValue: 24)
    public static let typeParameter = LSPCompletionItemKind(rawValue: 25)

    /// Every kind the spec names — the `valueSet` the client advertises, and the
    /// set a test can iterate to prove the mapping is total.
    public static let specified: [LSPCompletionItemKind] = (1...25).map(LSPCompletionItemKind.init(rawValue:))
}

/// Why the completion request fired.
public struct LSPCompletionTriggerKind: RawRepresentable, Equatable, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let invoked = LSPCompletionTriggerKind(rawValue: 1)
    public static let triggerCharacter = LSPCompletionTriggerKind(rawValue: 2)
    public static let triggerForIncompleteCompletions = LSPCompletionTriggerKind(rawValue: 3)
}

public struct LSPCompletionContext: Equatable, Hashable, Sendable, Codable {
    public var triggerKind: LSPCompletionTriggerKind
    public var triggerCharacter: String?

    public init(triggerKind: LSPCompletionTriggerKind, triggerCharacter: String? = nil) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
    }

    /// Ordinary identifier completion.
    public static let invoked = LSPCompletionContext(triggerKind: .invoked)
    /// Member completion, which is what `IdentifierScanner.memberContext` found.
    public static let dot = LSPCompletionContext(triggerKind: .triggerCharacter, triggerCharacter: ".")
}

public struct LSPCompletionParams: Equatable, Hashable, Sendable, Codable {
    public var textDocument: LSPTextDocumentIdentifier
    public var position: LSPPosition
    public var context: LSPCompletionContext?

    public init(
        textDocument: LSPTextDocumentIdentifier,
        position: LSPPosition,
        context: LSPCompletionContext? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
    }

    public init(uri: String, position: LSPPosition, context: LSPCompletionContext? = nil) {
        self.init(
            textDocument: LSPTextDocumentIdentifier(uri: uri),
            position: position,
            context: context
        )
    }
}

/// A replacement of one range with one string. Plain text always — D5 advertises
/// no snippet support, so nothing here ever needs `${1:placeholder}` stripped.
public struct LSPTextEdit: Equatable, Hashable, Sendable, Codable {
    public var range: LSPRange
    public var newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// A completion item's own edit, decoding both spellings the spec allows:
/// `TextEdit` (one `range`) and `InsertReplaceEdit` (an `insert` range and a
/// `replace` range).
///
/// `insertReplaceSupport` is *not* advertised, so only the first should ever
/// arrive; the second is decoded anyway because a server that sends it despite
/// that would otherwise take the whole completion list down with it. `range`
/// resolves to `replace` in that case — replacing the typed token is what the
/// editor does with the primary edit either way.
public struct LSPCompletionEdit: Equatable, Hashable, Sendable, Codable {
    public var range: LSPRange
    /// The narrower `insert` range of an `InsertReplaceEdit`, when that is what
    /// arrived. `nil` for a plain `TextEdit`.
    public var insertRange: LSPRange?
    public var newText: String

    public init(range: LSPRange, insertRange: LSPRange? = nil, newText: String) {
        self.range = range
        self.insertRange = insertRange
        self.newText = newText
    }

    private enum CodingKeys: String, CodingKey { case range, insert, replace, newText }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newText = try container.decode(String.self, forKey: .newText)
        if let range = try container.decodeIfPresent(LSPRange.self, forKey: .range) {
            self.range = range
            insertRange = nil
        } else {
            let replace = try container.decode(LSPRange.self, forKey: .replace)
            range = replace
            insertRange = try container.decodeIfPresent(LSPRange.self, forKey: .insert)
        }
    }

    /// Written back in the plain `TextEdit` spelling — the only one this client
    /// sends, and the one every server accepts on a `completionItem/resolve`
    /// echo.
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(range, forKey: .range)
        try container.encode(newText, forKey: .newText)
    }
}

/// One server-offered completion.
///
/// Decoded from a response *and* encoded back as `completionItem/resolve`'s
/// params, which is why every field round-trips — including `data`, the opaque
/// value a server correlates the resolve against (sourcekit-lsp's is
/// `{sessionId, itemId, uri}`; mangle it and the resolve answers nothing).
public struct LSPCompletionItem: Equatable, Hashable, Sendable, Codable {
    public var label: String
    public var kind: LSPCompletionItemKind?
    public var detail: String?
    /// The server's ranking key. D6 sorts by `sortText ?? label` and adds nothing.
    public var sortText: String?
    /// What the client should filter against, when it differs from `label`.
    public var filterText: String?
    /// The fallback when there is no `textEdit`; itself falling back to `label`.
    public var insertText: String?
    public var textEdit: LSPCompletionEdit?
    /// Edits elsewhere in the file that must land with the item — the `import`
    /// line of D4's auto-import.
    public var additionalTextEdits: [LSPTextEdit]?
    /// Present and `1` for plain text. Never a snippet (D5), but decoded so an
    /// item that claims otherwise can be recognised rather than mis-inserted.
    public var insertTextFormat: Int?
    public var deprecated: Bool?
    public var data: JSONValue?

    public init(
        label: String,
        kind: LSPCompletionItemKind? = nil,
        detail: String? = nil,
        sortText: String? = nil,
        filterText: String? = nil,
        insertText: String? = nil,
        textEdit: LSPCompletionEdit? = nil,
        additionalTextEdits: [LSPTextEdit]? = nil,
        insertTextFormat: Int? = nil,
        deprecated: Bool? = nil,
        data: JSONValue? = nil
    ) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.sortText = sortText
        self.filterText = filterText
        self.insertText = insertText
        self.textEdit = textEdit
        self.additionalTextEdits = additionalTextEdits
        self.insertTextFormat = insertTextFormat
        self.deprecated = deprecated
        self.data = data
    }

    /// The text this item puts in the buffer, by the spec's precedence:
    /// `textEdit.newText`, else `insertText`, else `label`.
    public var insertedText: String {
        textEdit?.newText ?? insertText ?? label
    }

    /// The key ranking sorts on (D6).
    public var rankingKey: String { sortText ?? label }

    /// Whether the item still needs `completionItem/resolve` before its edits are
    /// complete. `data` is the server's own signal that it kept something back;
    /// an item that already carries `additionalTextEdits` has nothing left to
    /// wait for.
    public var needsResolve: Bool {
        data != nil && (additionalTextEdits?.isEmpty ?? true)
    }
}

/// `textDocument/completion`'s result: a `CompletionList`, a bare array, or
/// `null`.
public struct LSPCompletionResponse: Equatable, Hashable, Sendable, Decodable {
    /// The server truncated the list and wants to be asked again as the user
    /// keeps typing. Recorded for the record; phase 2a re-asks on every keystroke
    /// anyway, because the completion controller is debounce-driven.
    public var isIncomplete: Bool
    public var items: [LSPCompletionItem]

    public init(isIncomplete: Bool = false, items: [LSPCompletionItem]) {
        self.isIncomplete = isIncomplete
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case isIncomplete, items }

    public init(from decoder: Swift.Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            isIncomplete = false
            items = []
            return
        }
        if let array = try? decoder.singleValueContainer().decode([LSPCompletionItem].self) {
            isIncomplete = false
            items = array
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isIncomplete = try container.decodeIfPresent(Bool.self, forKey: .isIncomplete) ?? false
        items = try container.decodeIfPresent([LSPCompletionItem].self, forKey: .items) ?? []
    }

    public var isEmpty: Bool { items.isEmpty }
}

// MARK: - Handshake

/// `$/cancelRequest`'s params — the one notification that carries a request id.
public struct LSPCancelParams: Equatable, Hashable, Sendable, Codable {
    public var id: LSPRequestID
    public init(id: LSPRequestID) { self.id = id }
}

public struct LSPClientInfo: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// Exactly the surface phase 2a uses, and nothing else.
///
/// Capabilities are a *promise*: a server reads them and decides what to send.
/// Advertising a feature the editor has no code for is how a client ends up with
/// snippet syntax in the buffer or an incremental sync it never implemented, so
/// this struct is deliberately a closed, hand-written list rather than a
/// pass-through of anything a caller might set:
///
/// * full text sync only (D2) — no willSave, no didSave, nothing to implement;
/// * `positionEncoding: utf-16`, stated rather than assumed (it is the default,
///   but a server that supports utf-8 will happily switch if asked, and every
///   offset in this codebase is UTF-16);
/// * definition with `linkSupport`, so a server that *can* name the identifier
///   range does (`LSPDefinitionTarget.jumpRange`);
/// * completion with `contextSupport` (the `.` trigger) and `resolveSupport` for
///   `additionalTextEdits` and `detail` — D4's auto-import arrives that way;
/// * **no** `snippetSupport` (D5), so `newText` is always literal text.
public struct LSPClientCapabilities: Equatable, Hashable, Sendable, Encodable {
    public init() {}

    public func encode(to encoder: Swift.Encoder) throws {
        var root = encoder.container(keyedBy: StringKey.self)

        var general = root.nestedContainer(keyedBy: StringKey.self, forKey: "general")
        try general.encode(["utf-16"], forKey: "positionEncodings")

        var textDocument = root.nestedContainer(keyedBy: StringKey.self, forKey: "textDocument")

        var sync = textDocument.nestedContainer(keyedBy: StringKey.self, forKey: "synchronization")
        try sync.encode(false, forKey: "dynamicRegistration")
        try sync.encode(false, forKey: "willSave")
        try sync.encode(false, forKey: "willSaveWaitUntil")
        try sync.encode(false, forKey: "didSave")

        var definition = textDocument.nestedContainer(keyedBy: StringKey.self, forKey: "definition")
        try definition.encode(false, forKey: "dynamicRegistration")
        try definition.encode(true, forKey: "linkSupport")

        var completion = textDocument.nestedContainer(keyedBy: StringKey.self, forKey: "completion")
        try completion.encode(false, forKey: "dynamicRegistration")
        try completion.encode(true, forKey: "contextSupport")

        var item = completion.nestedContainer(keyedBy: StringKey.self, forKey: "completionItem")
        try item.encode(false, forKey: "snippetSupport")
        try item.encode(false, forKey: "commitCharactersSupport")
        try item.encode(false, forKey: "deprecatedSupport")
        try item.encode(false, forKey: "preselectSupport")
        try item.encode(false, forKey: "insertReplaceSupport")
        try item.encode(["plaintext"], forKey: "documentationFormat")
        var resolve = item.nestedContainer(keyedBy: StringKey.self, forKey: "resolveSupport")
        try resolve.encode(["detail", "additionalTextEdits"], forKey: "properties")

        var kinds = completion.nestedContainer(keyedBy: StringKey.self, forKey: "completionItemKind")
        try kinds.encode(LSPCompletionItemKind.specified.map(\.rawValue), forKey: "valueSet")

        var workspace = root.nestedContainer(keyedBy: StringKey.self, forKey: "workspace")
        try workspace.encode(false, forKey: "workspaceFolders")
        try workspace.encode(false, forKey: "configuration")
    }

    /// A `CodingKey` that is just its string, so the capability tree above reads
    /// as the JSON it produces instead of as a dozen one-case enums.
    struct StringKey: CodingKey, ExpressibleByStringLiteral {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(stringLiteral value: String) { self.stringValue = value }
    }
}

public struct LSPInitializeParams: Equatable, Hashable, Sendable, Encodable {
    /// The editor's pid, so a server can exit if we vanish without an `exit`.
    public var processId: Int?
    public var clientInfo: LSPClientInfo?
    public var rootUri: String?
    public var capabilities: LSPClientCapabilities
    /// Per-server extra configuration from `LSPServerDescription` (D9).
    public var initializationOptions: JSONValue?

    public init(
        processId: Int?,
        clientInfo: LSPClientInfo? = nil,
        rootUri: String?,
        capabilities: LSPClientCapabilities = LSPClientCapabilities(),
        initializationOptions: JSONValue? = nil
    ) {
        self.processId = processId
        self.clientInfo = clientInfo
        self.rootUri = rootUri
        self.capabilities = capabilities
        self.initializationOptions = initializationOptions
    }

    private enum CodingKeys: String, CodingKey {
        case processId, clientInfo, rootUri, capabilities, initializationOptions
    }

    /// `processId` and `rootUri` are written even when nil — the spec types them
    /// `integer | null` and `string | null`, and a server is entitled to reject a
    /// request that omits them outright.
    public func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let processId {
            try container.encode(processId, forKey: .processId)
        } else {
            try container.encodeNil(forKey: .processId)
        }
        try container.encodeIfPresent(clientInfo, forKey: .clientInfo)
        if let rootUri {
            try container.encode(rootUri, forKey: .rootUri)
        } else {
            try container.encodeNil(forKey: .rootUri)
        }
        try container.encode(capabilities, forKey: .capabilities)
        if let initializationOptions {
            try container.encode(initializationOptions, forKey: .initializationOptions)
        }
    }
}

/// The bits of the server's answer this phase acts on.
///
/// Everything else in `capabilities` is ignored rather than modelled: a server
/// advertising twenty providers we do not call is not information, and typing it
/// would be twenty more shapes to keep decoding as servers evolve.
public struct LSPServerCapabilities: Equatable, Hashable, Sendable, Decodable {
    /// The encoding the server chose. Absent means utf-16 (the spec's default),
    /// which is what was asked for.
    public var positionEncoding: String?
    public var supportsDefinition: Bool
    public var supportsCompletion: Bool
    /// Whether `completionItem/resolve` is worth sending at all (D4's prefetch).
    public var resolvesCompletionItems: Bool
    public var completionTriggerCharacters: [String]

    public init(
        positionEncoding: String? = nil,
        supportsDefinition: Bool = false,
        supportsCompletion: Bool = false,
        resolvesCompletionItems: Bool = false,
        completionTriggerCharacters: [String] = []
    ) {
        self.positionEncoding = positionEncoding
        self.supportsDefinition = supportsDefinition
        self.supportsCompletion = supportsCompletion
        self.resolvesCompletionItems = resolvesCompletionItems
        self.completionTriggerCharacters = completionTriggerCharacters
    }

    private enum CodingKeys: String, CodingKey {
        case positionEncoding, definitionProvider, completionProvider
    }

    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        positionEncoding = try container.decodeIfPresent(String.self, forKey: .positionEncoding)

        // Both providers are `boolean | Options` on the wire. Presence of an
        // options object *is* support — a server that sends `{}` supports the
        // feature — so the two spellings collapse to one question.
        let definition = try container.decodeIfPresent(JSONValue.self, forKey: .definitionProvider)
        supportsDefinition = LSPServerCapabilities.isEnabled(definition)

        let completion = try container.decodeIfPresent(JSONValue.self, forKey: .completionProvider)
        supportsCompletion = LSPServerCapabilities.isEnabled(completion)
        resolvesCompletionItems = completion?["resolveProvider"]?.boolValue ?? false
        completionTriggerCharacters = completion?["triggerCharacters"]?
            .arrayValue?.compactMap(\.stringValue) ?? []
    }

    private static func isEnabled(_ value: JSONValue?) -> Bool {
        guard let value, !value.isNull else { return false }
        if let flag = value.boolValue { return flag }
        return value.objectValue != nil
    }

    /// Whether the server agreed to the encoding every offset in this codebase
    /// assumes. A server that answers `utf-8` here is not usable as-is, and the
    /// workspace treats that as unavailable rather than silently mis-mapping
    /// every position in a file with a single non-ASCII character.
    public var usesUTF16Positions: Bool {
        positionEncoding == nil || positionEncoding == "utf-16"
    }
}

public struct LSPServerInfo: Equatable, Hashable, Sendable, Decodable {
    public var name: String
    public var version: String?
}

public struct LSPInitializeResult: Equatable, Hashable, Sendable, Decodable {
    public var capabilities: LSPServerCapabilities
    public var serverInfo: LSPServerInfo?
}
