import Foundation
import PisakaCore
import XCTest

/// What the Welcome screen advertises is what the menus do.
///
/// A repository-file suite in the `MenuShortcutUniquenessTests` shape: it reads
/// `Sources/Pisaka` through `#filePath` with Foundation only, so it runs in
/// `swift test` without an Xcode build.
///
/// **Why nothing else can see this.** The Welcome screen draws chord strings
/// from `WelcomeAction` and `WelcomeFooterEntry`, while the chords themselves
/// are declared on menu `Button`s in the app layer. A menu chord moved, or a
/// command newly gated on an open folder, compiles and launches, and the screen
/// then advertises a shortcut that does something else or nothing at all — in
/// the one state it is ever drawn in, with no folder open.
///
/// The scan strips **comments only, keeping string literals** — the stated
/// exception `GitHubSourceGatingTests` and `MenuShortcutUniquenessTests` make,
/// for their reason: the menu titles and chord keys this rule matches *are*
/// string literals, so the ordinary scanner would delete them.
///
/// **The matching rule.** A *menu Button* is a `Button(` call; its *argument*
/// is the text up to its balanced closing parenthesis, and it *contains a
/// title* when that text holds the title as a string literal — so
/// `Button(bottomPanel == .terminal ? "Hide Terminal" : "Show Terminal")`
/// contains "Show Terminal". Its *chain* is what follows: an optional trailing
/// closure, then each `.modifier(…)` call in turn. Its *shortcut* is the first
/// `.keyboardShortcut("<key>", modifiers: <set>)` in that chain.
///
/// **What is pinned.**
/// - For every (title, chord) the two Core tables advertise, exactly one menu
///   Button whose argument contains the title carries the chord, and no Button
///   whose argument does not contain it carries the chord. Zoom In's ⌘+ thus
///   matches the second "Zoom In" item only; the ⌘= item is ignored.
/// - The **folder-required table**: every menu title whose chain carries
///   `.disabled(model.projectRoot == nil)` is stated below as a literal set and
///   held equal to the scan, and no advertised title is in it. A footer naming a
///   dead command fails, and so does a newly folder-gated command nobody
///   recorded here.
final class WelcomeShortcutPinTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PisakaCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // <root>

    /// Every menu title gated on an open folder. Closed: a new one fails
    /// `testFolderRequiredTableIsClosed` until it is recorded here.
    private static let folderRequiredTitles: Set<String> = [
        "Find in Files…",
        "Commit…",
    ]

    /// One `Button(` call: its argument's string literals, its chord and
    /// whether its chain disables it on a missing folder.
    private struct MenuButton {
        let literals: Set<String>
        let chord: WelcomeChord?
        let requiresFolder: Bool
        let location: String
    }

    // MARK: - The rules

    func testEveryAdvertisedChordBelongsToItsMenuItem() throws {
        let buttons = try menuButtons()
        XCTAssertGreaterThan(buttons.count, 30, "fewer Buttons were found than the app declares — the scan is broken")

        var pins: [(title: String, chord: WelcomeChord)] = WelcomeAction.allCases.map { ($0.menuTitle, $0.chord) }
        for entry in WelcomeFooterEntry.allCases {
            pins += entry.shortcuts.map { ($0.menuTitle, $0.chord) }
        }

        for pin in pins {
            let owners = buttons.filter { $0.literals.contains(pin.title) && $0.chord == pin.chord }
            XCTAssertEqual(owners.count, 1, """
                exactly one menu Button titled "\(pin.title)" must carry \(pin.chord.display); found \
                \(owners.count) — the Welcome screen advertises that chord for it
                """)
            let strangers = buttons.filter { !$0.literals.contains(pin.title) && $0.chord == pin.chord }
            XCTAssertTrue(strangers.isEmpty, """
                \(pin.chord.display) is also declared on a Button not titled "\(pin.title)", in \
                \(strangers.map(\.location).joined(separator: ", "))
                """)
        }
    }

    func testFolderRequiredTableIsClosed() throws {
        let scanned = try menuButtons().filter(\.requiresFolder)
        XCTAssertTrue(scanned.allSatisfy { $0.literals.count == 1 },
                      "a folder-gated Button has a computed title the table cannot name")
        let titles = Set(scanned.flatMap(\.literals))
        XCTAssertEqual(titles, Self.folderRequiredTitles, """
            the menu commands gated on `model.projectRoot == nil` changed; record the set here so the \
            Welcome screen cannot advertise one of them
            """)
    }

    func testNothingAdvertisedRequiresAFolder() {
        var advertised = Set(WelcomeAction.allCases.map(\.menuTitle))
        for entry in WelcomeFooterEntry.allCases {
            advertised.formUnion(entry.shortcuts.map(\.menuTitle))
        }
        XCTAssertTrue(advertised.isDisjoint(with: Self.folderRequiredTitles),
                      "the Welcome screen advertises a command that is disabled with no folder open")
    }

    /// The scanner itself, on a fixed input, so a parser that matches nothing
    /// cannot pass the rules above vacuously.
    func testTheScannerReadsTernaryTitlesTrailingClosuresAndChains() throws {
        let source = """
            Button(open ? "Hide Terminal" : "Show Terminal") {
                toggle(")")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Find in Files…") { find() }
                .keyboardShortcut("f", modifiers: [.shift, .command])
                .disabled(model.projectRoot == nil)
            Button("Plain") { act() }
            .keyboardShortcut("x", modifiers: .command)
            """
        let buttons = try Self.scanButtons(in: source, location: "fixture")
        XCTAssertEqual(buttons.count, 3)
        XCTAssertEqual(buttons[0].literals, ["Hide Terminal", "Show Terminal"])
        XCTAssertEqual(buttons[0].chord, WelcomeChord("t", [.command, .shift]))
        XCTAssertFalse(buttons[0].requiresFolder)
        XCTAssertEqual(buttons[1].chord, WelcomeChord("f", [.command, .shift]))
        XCTAssertTrue(buttons[1].requiresFolder)
        XCTAssertEqual(buttons[2].literals, ["Plain"])
        XCTAssertEqual(buttons[2].chord, WelcomeChord("x", [.command]))
    }

    // MARK: - The scan

    private func menuButtons() throws -> [MenuButton] {
        let directory = Self.repositoryRoot.appendingPathComponent("Sources/Pisaka")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            XCTFail("cannot enumerate \(directory.path)")
            return []
        }
        var found: [MenuButton] = []
        for url in enumerator.compactMap({ $0 as? URL }) where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let code = GitHubSourceGatingTests.strippingComments(source)
            found += try Self.scanButtons(in: code, location: url.lastPathComponent)
        }
        return found
    }

    private static func scanButtons(in code: String, location: String) throws -> [MenuButton] {
        let text = Array(code)
        let shortcutPattern = try NSRegularExpression(
            pattern: #"^\.keyboardShortcut\("(.)",\s*modifiers:\s*(\[[^\]]*\]|\.[a-zA-Z]+)\)$"#
        )
        let folderGate = try NSRegularExpression(pattern: #"^\.disabled\(\s*model\.projectRoot\s*==\s*nil\s*\)$"#)
        var buttons: [MenuButton] = []
        var index = 0
        while index < text.count {
            if let skipped = skipLiteral(text, from: index) {
                index = skipped
                continue
            }
            guard matches(text, "Button(", at: index), index == 0 || !isIdentifier(text[index - 1]) else {
                index += 1
                continue
            }
            let open = index + "Button".count
            let close = balancedEnd(text, from: open, opening: "(", closing: ")")
            let argument = String(text[open..<close])
            var cursor = skipSpace(text, from: close)
            if cursor < text.count, text[cursor] == "{" {
                cursor = skipSpace(text, from: balancedEnd(text, from: cursor, opening: "{", closing: "}"))
            }
            var chord: WelcomeChord?
            var requiresFolder = false
            while cursor < text.count, text[cursor] == "." {
                var nameEnd = cursor + 1
                while nameEnd < text.count, isIdentifier(text[nameEnd]) { nameEnd += 1 }
                guard nameEnd < text.count, text[nameEnd] == "(" else { break }
                let callEnd = balancedEnd(text, from: nameEnd, opening: "(", closing: ")")
                let call = String(text[cursor..<callEnd])
                let range = NSRange(call.startIndex..., in: call)
                if chord == nil, let match = shortcutPattern.firstMatch(in: call, range: range),
                   let key = Range(match.range(at: 1), in: call), let mods = Range(match.range(at: 2), in: call) {
                    chord = WelcomeChord(Character(String(call[key])), modifiers(String(call[mods])))
                }
                if folderGate.firstMatch(in: call, range: range) != nil { requiresFolder = true }
                cursor = skipSpace(text, from: callEnd)
            }
            buttons.append(MenuButton(
                literals: stringLiterals(in: argument),
                chord: chord,
                requiresFolder: requiresFolder,
                location: location
            ))
            index = open
        }
        return buttons
    }

    private static func modifiers(_ spelled: String) -> Set<WelcomeModifier> {
        Set(spelled
            .split(whereSeparator: { " [],.".contains($0) })
            .compactMap { WelcomeModifier(rawValue: String($0)) })
    }

    /// The contents of each plain string literal in `text`.
    private static func stringLiterals(in text: String) -> Set<String> {
        let characters = Array(text)
        var literals: Set<String> = []
        var index = 0
        while index < characters.count {
            if characters[index] == "\"", let end = skipLiteral(characters, from: index) {
                literals.insert(String(characters[(index + 1)..<(end - 1)]))
                index = end
            } else {
                index += 1
            }
        }
        return literals
    }

    /// The index after the string literal starting at `index`, or `nil` when no
    /// literal starts there. Escapes and interpolations are stepped over; a raw
    /// string (`#"…"#`) ends at its own delimiter and has no escapes to step.
    private static func skipLiteral(_ text: [Character], from index: Int) -> Int? {
        guard index < text.count else { return nil }
        if text[index] == "#", index == 0 || !isIdentifier(text[index - 1]) {
            var hashes = 0
            while index + hashes < text.count, text[index + hashes] == "#" { hashes += 1 }
            guard index + hashes < text.count, text[index + hashes] == "\"" else { return nil }
            let multiline = matches(text, "\"\"\"", at: index + hashes)
            let closing = (multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: hashes)
            var cursor = index + hashes + (multiline ? 3 : 1)
            while cursor < text.count, !matches(text, closing, at: cursor) { cursor += 1 }
            return min(cursor + closing.count, text.count)
        }
        guard text[index] == "\"" else { return nil }
        let delimiter = matches(text, "\"\"\"", at: index) ? "\"\"\"" : "\""
        var cursor = index + delimiter.count
        while cursor < text.count {
            if text[cursor] == "\\" {
                if cursor + 1 < text.count, text[cursor + 1] == "(" {
                    cursor = balancedEnd(text, from: cursor + 1, opening: "(", closing: ")")
                } else {
                    cursor += 2
                }
            } else if matches(text, delimiter, at: cursor) {
                return cursor + delimiter.count
            } else {
                cursor += 1
            }
        }
        return text.count
    }

    /// The index after the bracket matching the one at `index`, skipping
    /// string literals.
    private static func balancedEnd(_ text: [Character], from index: Int, opening: Character, closing: Character) -> Int {
        var depth = 0
        var cursor = index
        while cursor < text.count {
            if let skipped = skipLiteral(text, from: cursor) {
                cursor = skipped
                continue
            }
            if text[cursor] == opening { depth += 1 }
            if text[cursor] == closing {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return text.count
    }

    private static func skipSpace(_ text: [Character], from index: Int) -> Int {
        var cursor = index
        while cursor < text.count, text[cursor].isWhitespace { cursor += 1 }
        return cursor
    }

    private static func matches(_ text: [Character], _ needle: String, at index: Int) -> Bool {
        let needle = Array(needle)
        guard index + needle.count <= text.count else { return false }
        return Array(text[index..<(index + needle.count)]) == needle
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
