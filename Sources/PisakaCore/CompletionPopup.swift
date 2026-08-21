import Foundation

/// State and mapping for the completion popup.
///
/// This file ranks nothing and filters nothing: it receives the provider's
/// order and renders it into rows, plus selection state for the UI.
public enum CompletionPopup {

    /// The selection state of the completion popup.
    public struct Selection: Equatable, Sendable {
        public let count: Int
        public private(set) var selectedIndex: Int

        public init?(count: Int) {
            guard count > 0 else { return nil }
            self.count = count
            self.selectedIndex = 0
        }

        public mutating func moveUp() {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
        }

        public mutating func moveDown() {
            if selectedIndex < count - 1 {
                selectedIndex += 1
            }
        }

        public mutating func select(_ index: Int) {
            if index >= 0 && index < count {
                selectedIndex = index
            }
        }
    }

    /// The semantic source of a completion row.
    public enum RowSource: Equatable, Sendable {
        case symbol(SymbolKind)
        case keyword
        case word
    }

    /// The visual badge for a row.
    public struct Badge: Equatable, Sendable {
        public let symbolName: String
        public let color: FileIconColor

        public init(symbolName: String, color: FileIconColor) {
            self.symbolName = symbolName
            self.color = color
        }

        public init(source: RowSource) {
            switch source {
            case .symbol(let kind):
                switch kind {
                case .type: self.init(symbolName: "t.square", color: .purple)
                case .function, .method: self.init(symbolName: "f.cursive", color: .purple)
                case .property: self.init(symbolName: "p.square", color: .blue)
                case .constant: self.init(symbolName: "c.square", color: .blue)
                case .variable: self.init(symbolName: "v.square", color: .blue)
                case .heading: self.init(symbolName: "number", color: .gray)
                case .selector: self.init(symbolName: "s.square", color: .pink)
                case .key: self.init(symbolName: "k.square", color: .yellow)
                case .stage: self.init(symbolName: "shippingbox", color: .orange)
                case .anchor: self.init(symbolName: "link", color: .gray)
                }
            case .keyword:
                self.init(symbolName: "k.circle", color: .pink)
            case .word:
                self.init(symbolName: "text.word.spacing", color: .gray)
            }
        }
    }

    /// One row in the popup.
    public struct Row: Equatable, Sendable {
        public let displayText: String
        public let badge: Badge
        public let item: CompletionItem

        public init(displayText: String, badge: Badge, item: CompletionItem) {
            self.displayText = displayText
            self.badge = badge
            self.item = item
        }

        public static func rows(
            for items: [CompletionItem],
            language: SyntaxLanguage?
        ) -> [Row] {
            let keywords = language.map { Set(LanguageKeywords.keywords(for: $0)) } ?? []
            var seen = Set<String>()
            var rows: [Row] = []

            for item in items {
                let text = item.displayText
                if seen.insert(text).inserted {
                    let source: RowSource
                    if let kind = item.kind {
                        source = .symbol(kind)
                    } else if keywords.contains(item.text) {
                        source = .keyword
                    } else {
                        source = .word
                    }
                    rows.append(Row(displayText: text, badge: Badge(source: source), item: item))
                }
            }
            return rows
        }
    }
}

// Aliases for the requested names
public typealias CompletionPopupSelection = CompletionPopup.Selection
public typealias CompletionRowSource = CompletionPopup.RowSource
public typealias CompletionBadge = CompletionPopup.Badge
public typealias CompletionRow = CompletionPopup.Row
