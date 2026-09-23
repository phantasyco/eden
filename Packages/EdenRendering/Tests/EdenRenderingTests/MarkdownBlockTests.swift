import EdenRendering
import Testing

@Suite("Markdown blocks")
struct MarkdownBlockTests {
    @Test func paragraphsSplitOnBlankLinesAndKeepLineBreaks() {
        let blocks = MarkdownBlock.parse("One line.\nSame stanza.\n\nNext stanza.")
        #expect(blocks == [.paragraph("One line.\nSame stanza."), .paragraph("Next stanza.")])
    }

    @Test func headingsCarryTheirLevel() {
        #expect(MarkdownBlock.parse("# Title\n### Small") == [.heading(level: 1, text: "Title"), .heading(level: 3, text: "Small")])
    }

    @Test func fencedCodeKeepsItsLanguageAndText() {
        let blocks = MarkdownBlock.parse("```swift\nlet x = 1\n\nprint(x)\n```")
        #expect(blocks == [.code(language: "swift", text: "let x = 1\n\nprint(x)")])
    }

    @Test func listsKeepMarkersAndNesting() throws {
        let blocks = MarkdownBlock.parse("- one\n  - nested\n- two\n\n1. first\n2. second")
        guard case .list(let bullets) = try #require(blocks.first) else {
            Issue.record("expected a list, got \(blocks)")
            return
        }
        #expect(bullets.map(\.text) == ["one", "nested", "two"])
        #expect(bullets.map(\.level) == [0, 1, 0])
        guard case .list(let numbered) = try #require(blocks.last) else {
            Issue.record("expected a numbered list, got \(blocks)")
            return
        }
        #expect(numbered.map(\.marker) == ["1.", "2."])
    }

    @Test func quotesTablesAndRules() {
        let blocks = MarkdownBlock.parse("> quoted\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---")
        #expect(blocks == [.quote("quoted"), .table(header: ["A", "B"], rows: [["1", "2"]]), .rule])
    }
}
