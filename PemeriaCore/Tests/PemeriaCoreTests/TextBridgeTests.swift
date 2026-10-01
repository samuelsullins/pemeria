import Foundation
import Testing
@testable import PemeriaCore

struct TextBridgeTests {
    @Test func buildsLinesWithStylesAndBookmarks() {
        let blocks: [Block] = [
            .paragraph(Paragraph(runs: [Run("The lamp was "), Run("dark", .italic), Run(".")])),
            .bookmark(Bookmark(id: "b7c1", name: "Storm")),
            .paragraph(Paragraph("Rain.")),
        ]
        let text = TextBridge.attributedString(blocks)
        #expect(text.string == "The lamp was dark.\n\u{2060}\nRain.")
        #expect((text.attribute(.pemeriaStyle, at: 13, effectiveRange: nil) as? NSNumber)?.uint8Value == InlineStyle.italic.rawValue)
        #expect(text.attribute(.pemeriaStyle, at: 0, effectiveRange: nil) == nil)
        #expect((text.attribute(.pemeriaBookmark, at: 19, effectiveRange: nil) as? BookmarkMarker)?.bookmark.name == "Storm")
        #expect(TextBridge.blocks(from: text) == blocks)
    }

    @Test func emptyText() {
        let empty = NSAttributedString(string: "")
        #expect(TextBridge.blocks(from: empty) == [.paragraph(Paragraph(runs: []))])
        #expect(TextBridge.blocks(from: empty, emptyMeansNone: true) == [])
        #expect(TextBridge.blocks(from: NSAttributedString(string: "\n")) == [
            .paragraph(Paragraph(runs: [])), .paragraph(Paragraph(runs: [])),
        ])
    }

    @Test func bookmarkSharingALineKeepsTheWords() {
        let text = TextBridge.attributedString([.bookmark(Bookmark(id: "ab12", name: "x"))])
        text.append(NSAttributedString(string: "joined text"))
        #expect(TextBridge.blocks(from: text) == [
            .bookmark(Bookmark(id: "ab12", name: "x")),
            .paragraph(Paragraph("joined text")),
        ])
    }

    @Test func strayMarkerCharactersAreDropped() {
        // e.g. a bookmark copied and pasted, which loses its attribute on the way.
        let text = NSAttributedString(string: "a\u{2060}b\n\u{2060}")
        #expect(TextBridge.blocks(from: text) == [.paragraph(Paragraph("ab")), .paragraph(Paragraph(runs: []))])
    }

    @Test func randomBlocksRoundTrip() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<3_000 {
            let blocks = Block.canonical(randomBlocks(using: &rng))
            let text = TextBridge.attributedString(blocks)
            let expected = blocks.isEmpty ? [.paragraph(Paragraph(runs: []))] : blocks
            #expect(TextBridge.blocks(from: text) == expected)
        }
    }
}
