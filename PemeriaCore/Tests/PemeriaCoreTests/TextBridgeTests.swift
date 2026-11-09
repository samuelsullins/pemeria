import Foundation
import Testing
@testable import PemeriaCore

struct TextBridgeTests {
    @Test func buildsLinesWithStylesAndDropsOldBookmarks() {
        let blocks: [Block] = [
            .paragraph(Paragraph(runs: [Run("The lamp was "), Run("dark", .italic), Run(".")])),
            .bookmark(Bookmark(id: "b7c1", name: "Storm", offset: 5)),
            .paragraph(Paragraph("# Storm\\ Rain came.")),
        ]
        let text = TextBridge.attributedString(blocks)
        #expect(text.string == "The lamp was dark.\n# Storm\\ Rain came.")
        #expect((text.attribute(.pemeriaStyle, at: 13, effectiveRange: nil) as? NSNumber)?.uint8Value == InlineStyle.italic.rawValue)
        #expect(text.attribute(.pemeriaStyle, at: 0, effectiveRange: nil) == nil)
        // Old-style bookmark lines aren't shown, so they're gone once the text is saved.
        #expect(TextBridge.blocks(from: text) == [blocks[0], blocks[2]])
    }

    @Test func emptyText() {
        let empty = NSAttributedString(string: "")
        #expect(TextBridge.blocks(from: empty) == [.paragraph(Paragraph(runs: []))])
        #expect(TextBridge.blocks(from: empty, emptyMeansNone: true) == [])
        #expect(TextBridge.blocks(from: NSAttributedString(string: "\n")) == [
            .paragraph(Paragraph(runs: [])), .paragraph(Paragraph(runs: [])),
        ])
    }

    @Test func oldBookmarksStillCanonicalize() {
        let blocks = Block.canonical([.paragraph(Paragraph("abc")), .bookmark(Bookmark(id: "ab12", name: "x"))])
        #expect(blocks == [.bookmark(Bookmark(id: "ab12", name: "x", offset: 3)), .paragraph(Paragraph("abc"))])
    }

    @Test func strayMarkerCharactersAreDropped() {
        // e.g. a divider's stand-in character copied and pasted.
        let text = NSAttributedString(string: "a\u{2060}b\n\u{FFFC}")
        #expect(TextBridge.blocks(from: text) == [.paragraph(Paragraph("ab")), .paragraph(Paragraph(runs: []))])
    }

    @Test func randomBlocksRoundTrip() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<3_000 {
            let blocks = Block.canonical(randomBlocks(using: &rng))
            let text = TextBridge.attributedString(blocks)
            let paragraphs = blocks.filter { if case .paragraph = $0 { true } else { false } }
            let expected = paragraphs.isEmpty ? [.paragraph(Paragraph(runs: []))] : paragraphs
            #expect(TextBridge.blocks(from: text) == expected)
            #expect(Block.canonical(expected) == expected)
        }
    }
}
