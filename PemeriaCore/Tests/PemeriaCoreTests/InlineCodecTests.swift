import Testing
@testable import PemeriaCore

struct InlineCodecTests {
    @Test(arguments: [
        (Paragraph(runs: [Run("plain")]), "plain"),
        (Paragraph(runs: [Run("eleven", .italic)]), "*eleven*"),
        (Paragraph(runs: [Run("hard", .bold)]), "**hard**"),
        (Paragraph(runs: [Run("both", [.bold, .italic])]), "***both***"),
        (Paragraph(runs: [Run("un"), Run("believ", .italic), Run("able")]), "un*believ*able"),
        (Paragraph(runs: [Run("a ", .italic), Run("b", [.italic, .bold]), Run(" c", .italic)]), "*a **b** c*"),
        (Paragraph(runs: [Run("2 * 3 \\ 4")]), "2 \\* 3 \\\\ 4"),
        (Paragraph(runs: [Run("see <!-- this")]), "see \\<!-- this"),
        (Paragraph(runs: [Run("<b> is fine")]), "<b> is fine"),
        (Paragraph(runs: [Run("*", .italic)]), "*\\**"),
        (Paragraph(runs: []), ""),
    ])
    func encodesExamples(paragraph: Paragraph, line: String) {
        #expect(bytes(InlineCodec.encode(paragraph)) == bytes(line))
        #expect(InlineCodec.decode(line) == paragraph.normalized())
    }

    @Test func edgeWhitespaceMovesOutsideMarkers() {
        let paragraph = Paragraph(runs: [Run("She said "), Run(" no ", .italic), Run("twice.")])
        #expect(InlineCodec.encode(paragraph) == "She said  *no* twice.")
    }

    @Test func whitespaceOnlyStyledRunBecomesPlain() {
        let paragraph = Paragraph(runs: [Run("a"), Run("  ", .bold), Run("b")])
        #expect(paragraph.normalized() == Paragraph(runs: [Run("a  b")]))
    }

    @Test func accentNextToFormattingSurvives() {
        // An accent styled differently from the letter it sits on.
        let paragraph = Paragraph(runs: [Run("e", .italic), Run("\u{301}x")])
        let decoded = InlineCodec.decode(InlineCodec.encode(paragraph))
        #expect(decoded == paragraph.normalized())
        #expect(bytes(decoded.text) == bytes("e\u{301}x"))
    }

    @Test func handEditedLinesDecodeSensibly() {
        #expect(InlineCodec.decode("trailing \\") == Paragraph(runs: [Run("trailing \\")]))
        #expect(InlineCodec.decode("*never closed") == Paragraph(runs: [Run("never closed", .italic)]))
        #expect(InlineCodec.decode("****") == Paragraph(runs: []))
        #expect(InlineCodec.decode("a*****b") == Paragraph(runs: [Run("a"), Run("b", .italic)]))
    }

    @Test func randomParagraphsRoundTrip() {
        var rng = SeededGenerator(seed: 1)
        for _ in 0..<5_000 {
            let paragraph = randomParagraph(using: &rng)
            let line = InlineCodec.encode(paragraph)
            let decoded = InlineCodec.decode(line)
            #expect(decoded == paragraph.normalized(), "line: \(line.debugDescription)")
            #expect(bytes(decoded.text) == bytes(paragraph.text), "characters changed: \(line.debugDescription)")
            #expect(bytes(InlineCodec.encode(decoded)) == bytes(line))
        }
    }

    @Test func arbitraryLinesReachAFixedPoint() {
        var rng = SeededGenerator(seed: 2)
        for _ in 0..<5_000 {
            let line = (0..<Int.random(in: 0...12, using: &rng))
                .map { _ in trickyPieces.randomElement(using: &rng)! }
                .joined()
            let once = InlineCodec.decode(line)
            let twice = InlineCodec.decode(InlineCodec.encode(once))
            #expect(once == twice, "line: \(line.debugDescription)")
        }
    }
}
