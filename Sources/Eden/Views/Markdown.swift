import AppKit
import SwiftUI

/// Agent replies as Markdown: headings, lists, quotes, tables, rules, and
/// fenced code, with inline styles inside each. Not a full CommonMark parser;
/// it covers what coding agents write.
struct MarkdownText: View {
    /// Runs of prose (paragraphs, headings, lists, quotes) as one text view
    /// each, so a selection runs across paragraphs like in a document; code
    /// blocks, tables, and rules sit between them as views of their own.
    private enum Segment {
        case prose([MarkdownBlock])
        case block(MarkdownBlock)
    }

    private let segments: [Segment]

    init(_ source: String) {
        var segments: [Segment] = []
        var prose: [MarkdownBlock] = []
        for block in MarkdownBlock.parse(source) {
            switch block {
            case .paragraph, .heading, .list, .quote:
                prose.append(block)
            case .code, .table, .rule:
                if !prose.isEmpty { segments.append(.prose(prose)) }
                prose = []
                segments.append(.block(block))
            }
        }
        if !prose.isEmpty { segments.append(.prose(prose)) }
        self.segments = segments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks): ProseView(blocks: blocks)
                case .block(let block): BlockView(block: block)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Prose in a read-only AppKit text view: one selection across every
/// paragraph, list, and quote in it (SwiftUI's Text selects within one
/// Text only), links that open, and Copy, Look Up, and Services for free.
private struct ProseView: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    @AppStorage(Preferences.theme) private var theme = Theme.eden

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 1, whose glyph rects place the quote's bar.
        let view = ProseTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.secondaryLabelColor,
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    final class Coordinator {
        var blocks: [MarkdownBlock]?
        var theme: Theme?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Builds the text only when the Markdown or the theme changed: SwiftUI
    /// updates the view far more often than that, a resize every frame.
    func updateNSView(_ view: NSTextView, context: Context) {
        let built = context.coordinator
        guard built.blocks != blocks || built.theme != theme else { return }
        built.blocks = blocks
        built.theme = theme
        view.textStorage?.setAttributedString(Prose.attributed(blocks, tint: NSColor(theme.color)))
    }

    /// Measured on a copy, never on the view itself: SwiftUI asks at widths
    /// it doesn't end up using, and re-wrapping the visible text for each of
    /// those made it flicker while the window resized.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let text = view.textStorage else { return nil }
        let fallback = view.bounds.width > 0 ? view.bounds.width : 640
        let width = min(max(proposal.width ?? fallback, 1), 10_000)
        return CGSize(width: width, height: ProseMeasure.height(of: text, width: width))
    }
}

/// Lays text out off screen to find its height at a width, with the same
/// TextKit setup as the view, and remembers recent answers: a resize asks
/// about the same few widths over and over.
@MainActor
private enum ProseMeasure {
    private static let storage = NSTextStorage()
    private static let layout: NSLayoutManager = {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return layout
    }()
    private static let container: NSTextContainer = {
        let container = NSTextContainer()
        container.lineFragmentPadding = 0
        return container
    }()
    private static var cache: [Int: CGFloat] = [:]

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        var hasher = Hasher()
        hasher.combine(text.string)
        hasher.combine(text.length)
        hasher.combine(Int(width.rounded()))
        let key = hasher.finalize()
        if let known = cache[key] { return known }
        if storage != text { storage.setAttributedString(text) }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = height
        return height
    }
}

/// Markdown prose as one attributed string, styled like the SwiftUI blocks:
/// body text with 3 points between lines and 10 between paragraphs, bold
/// headings, lists with hanging indents and accent bullets, quotes behind
/// an accent bar.
enum Prose {
    private static let body = NSFont.preferredFont(forTextStyle: .body)

    static func attributed(_ blocks: [MarkdownBlock], tint: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            switch block {
            case .paragraph(let source):
                text.append(paragraph(inline(source, font: body, color: .labelColor, tint: tint), spacing: last ? 0 : 10))
            case .heading(let level, let source):
                let size = level == 1 ? NSFont.preferredFont(forTextStyle: .title2).pointSize
                    : level == 2 ? NSFont.preferredFont(forTextStyle: .title3).pointSize : body.pointSize
                let font = NSFont.systemFont(ofSize: size, weight: level == 1 ? .bold : .semibold)
                text.append(paragraph(inline(source, font: font, color: .labelColor, tint: tint),
                                      spacing: last ? 0 : 8, before: index == 0 ? 0 : level <= 2 ? 6 : 2))
            case .list(let items):
                for (position, item) in items.enumerated() {
                    let indent = CGFloat(item.level) * 20
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 3
                    style.firstLineHeadIndent = indent
                    style.headIndent = indent + 22
                    style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                    style.paragraphSpacing = position == items.count - 1 ? (last ? 0 : 10) : 5
                    let bullet = item.marker == "•"
                    let line = NSMutableAttributedString(string: item.marker + "\t", attributes: [
                        .font: bullet ? body : NSFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular),
                        .foregroundColor: bullet ? (item.level == 0 ? tint : NSColor.tertiaryLabelColor) : NSColor.secondaryLabelColor,
                    ])
                    line.append(inline(item.text, font: body, color: .labelColor, tint: tint))
                    line.append(NSAttributedString(string: "\n"))
                    line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                    text.append(line)
                }
            case .quote(let source):
                // Indented, with room above and below for the panel ProseTextView draws behind it.
                let quote = paragraph(inline(source, font: body, color: .secondaryLabelColor, tint: tint),
                                      spacing: last ? 6 : 16, before: index == 0 ? 6 : 6, indent: 12)
                quote.addAttribute(.quote, value: tint, range: NSRange(location: 0, length: quote.length - 1))
                text.append(quote)
            default:
                break
            }
        }
        // No empty line after the last paragraph.
        if text.string.hasSuffix("\n") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        return text
    }

    /// A paragraph ending in a newline, with the spacing around it.
    private static func paragraph(_ content: NSAttributedString, spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        let line = NSMutableAttributedString(attributedString: content)
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// Inline Markdown in AppKit terms, matching the SwiftUI version: bold,
    /// italic, code with a faint accent wash, links in the body color.
    private static func inline(_ source: String, font: NSFont, color: NSColor, tint: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            // A line break inside a paragraph stays inside it: no paragraph spacing between a stanza's lines.
            let piece = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) : font
            var traits = runFont.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if traits != runFont.fontDescriptor.symbolicTraits {
                runFont = NSFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(traits), size: runFont.pointSize) ?? runFont
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if intent.contains(.code) { attributes[.backgroundColor] = tint.withAlphaComponent(0.14) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var level: Int
        var marker: String
        var text: String
    }

    case paragraph(String)
    case heading(level: Int, text: String)
    case list([ListItem])
    case quote(String)
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
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

/// Inline Markdown (bold, italic, code, links) for one run of text. Inline
/// code gets a faint accent wash so it reads as code without a heavy box (the
/// text keeps the body color, which stays legible on every theme), and
/// links keep the body color with a muted underline: in a reply full of file
/// names and URLs, blue links would outshout the text.
private func inline(_ text: String, tint: Color = Theme.eden.color) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in string.runs {
        if run.inlinePresentationIntent?.contains(.code) == true {
            // A point smaller than the text: monospaced faces run large.
            string[run.range].font = .system(.callout, design: .monospaced)
            string[run.range].backgroundColor = tint.opacity(0.14)
        }
        if run.link != nil {
            string[run.range].foregroundColor = .primary
            string[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: .secondary)
        }
    }
    return string
}

private struct BlockView: View {
    let block: MarkdownBlock
    @Environment(\.colorScheme) private var colorScheme
    /// Attributed strings need a concrete color, not the environment's tint.
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    private var tint: Color { theme.color }

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text, tint: tint))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            Text(inline(text, tint: tint))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inline(item.text, tint: tint))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 20)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.tint)
                    .frame(width: 2)
                Text(inline(text, tint: tint))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 10)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03), in: RoundedRectangle(cornerRadius: 6))
        case .code(let language, let text):
            CodeBlock(language: language, text: text)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// Bullets are small accent dots; numbers stay text, in the secondary color.
    @ViewBuilder private func marker(_ item: MarkdownBlock.ListItem) -> some View {
        if item.marker == "•" {
            // Text sized to the line so the dot sits on the first baseline.
            Text(" ")
                .overlay {
                    Circle()
                        .fill(item.level == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .frame(width: 5, height: 5)
                }
        } else {
            Text(item.marker)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// A fenced code block: language and Copy on a slim header, code that scrolls sideways.
private struct CodeBlock: View {
    let language: String
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "Code" : language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().opacity(0.6)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .scrollIndicators(.automatic)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }
}

/// A Markdown table as a grid with a bold header row and hairlines between
/// rows, and no frame around it, like a table in Notes.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]
    @AppStorage(Preferences.theme) private var theme = Theme.eden

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell, tint: theme.color)).fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { position, row in
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            Text(inline(column < row.count ? row[column] : "", tint: theme.color))
                        }
                    }
                    if position < rows.count - 1 { Divider().opacity(0.5) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}


extension NSAttributedString.Key {
    /// A quote's text; the value is the accent color for its bar.
    static let quote = NSAttributedString.Key("EdenQuote")
}

/// Draws each quote's accent bar and faint panel behind its text.
private final class ProseTextView: NSTextView {
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(.quote, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let tint = value as? NSColor else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let text = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let panel = NSRect(x: 0, y: text.minY - 6, width: bounds.width, height: text.height + 12)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6).fill()
            tint.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: panel.minY, width: 2, height: panel.height), xRadius: 1, yRadius: 1).fill()
        }
    }
}
