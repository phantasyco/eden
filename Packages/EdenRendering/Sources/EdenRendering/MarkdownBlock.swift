import Foundation

/// A reply's Markdown, split into blocks: paragraphs, headings, lists,
/// quotes, fenced code, tables, and rules. Not a full CommonMark parser;
/// it covers what coding agents write.
public enum MarkdownBlock: Equatable, Sendable {
    public struct ListItem: Equatable, Sendable {
        public var level: Int
        public var marker: String
        public var text: String

        public init(level: Int, marker: String, text: String) {
            self.level = level
            self.marker = marker
            self.text = text
        }
    }

    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ListItem])
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    public static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = headingLevel(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading, text: String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index]))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if listItem(line) != nil {
                flushParagraph()
                var items: [ListItem] = []
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    } else if let item = listItem(lines[index]) {
                        items.append(item)
                    } else if !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, lines[index].hasPrefix("  "), !items.isEmpty {
                        // A wrapped continuation of the previous item.
                        items[items.count - 1].text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// "- item", "* item", "1. item", or "1) item", indented two spaces per level.
    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return ListItem(level: indent / 2, marker: "•", text: String(rest.dropFirst(2)))
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let punctuation = after.first, ".)".contains(punctuation), after.dropFirst().first == " " {
                return ListItem(level: indent / 2, marker: "\(digits).", text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
