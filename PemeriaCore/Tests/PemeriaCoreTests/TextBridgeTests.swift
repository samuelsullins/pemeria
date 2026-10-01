import Foundation
import Testing
@testable import PemeriaCore

struct TextBridgeTests {
    @Test func buildsLinesWithStylesAndInlineBookmarks() {
        let blocks: [Block] = [
            .paragraph(Paragraph(runs: [Run("The lamp was "), Run("dark", .italic), Run(".")])),
            .bookmark(Bookmark(id: "b7c1", name: "Storm", offset: 5)),
            .paragraph(Paragraph("Rain came.")),
        ]
        let text = TextBridge.attributedString(blocks)
        #expect(text.string == "The lamp was dark.\nRain \u{2060}came.")
        #expect((text.attribute(.pemeriaStyle, at: 13, effectiveRange: nil) as? NSNumber)?.uint8Value == InlineStyle.italic.rawValue)
        #expect(text.attribute(.pemeriaStyle, at: 0, effectiveRange: nil) == nil)
        #expect((text.attribute(.pemeriaBookmark, at: 24, effectiveRange: nil) as? BookmarkMarker)?.bookmark.name == "Storm")
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

    @Test func editsMoveBookmarkWithTheText() {
        let text = TextBridge.attributedString([
            .bookmark(Bookmark(id: "ab12", name: "x", offset: 4)),
            .paragraph(Paragraph("some words")),
        ])
        text.insert(NSAttributedString(string: "Hello, "), at: 0)
        #expect(TextBridge.blocks(from: text) == [
            .bookmark(Bookmark(id: "ab12", name: "x", offset: 11)),
            .paragraph(Paragraph("Hello, some words")),
        ])
    }

    @Test func bookmarksWithoutAParagraphAfterThemAttachToTheOneBefore() {
        let blocks = Block.canonical([.paragraph(Paragraph("abc")), .bookmark(Bookmark(id: "ab12", name: "x"))])
        #expect(blocks == [.bookmark(Bookmark(id: "ab12", name: "x", offset: 3)), .paragraph(Paragraph("abc"))])
        #expect(Block.canonical([.bookmark(Bookmark(id: "ab12", name: "x", offset: 9))]) == [
            .bookmark(Bookmark(id: "ab12", name: "x", offset: 0)), .paragraph(Paragraph(runs: [])),
        ])
    }

    @Test func strayMarkerCharactersAreDropped() {
        // e.g. a bookmark copied and pasted, which loses its attribute on the way.
        let text = NSAttributedString(string: "a\u{2060}b\n\u{FFFC}")
        #expect(TextBridge.blocks(from: text) == [.paragraph(Paragraph("ab")), .paragraph(Paragraph(runs: []))])
    }

    @Test func randomBlocksRoundTrip() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<3_000 {
            let blocks = Block.canonical(randomBlocks(using: &rng))
            let text = TextBridge.attributedString(blocks)
            let expected = blocks.isEmpty ? [.paragraph(Paragraph(runs: []))] : blocks
            #expect(TextBridge.blocks(from: text) == expected)
            #expect(Block.canonical(expected) == expected)
        }
    }
}
