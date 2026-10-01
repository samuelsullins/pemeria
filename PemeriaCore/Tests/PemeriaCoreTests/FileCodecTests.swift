import Testing
@testable import PemeriaCore

struct FileCodecTests {
    static let specExample = """
        ---
        id: k3f9a2
        title: The Lighthouse
        parent: p81xq0
        order: V
        kind: draft
        icons: inciting-incident, crisis
        ---
        The lamp had been dark for *eleven* years.
        She climbed anyway. // Too abrupt? Maybe add a beat here.
        <!-- bookmark b7c1: The storm starts -->
        Rain came sideways off the water — **hard**.
        <!-- outline -->
        Mara reaches the lighthouse. Finds the logbook. Storm hits.

        """

    @Test func decodesSpecExample() {
        let file = FileCodec.decode(Self.specExample, fallbackID: "zzzzzz")
        #expect(file.id == "k3f9a2")
        #expect(file.title == "The Lighthouse")
        #expect(file.parent == "p81xq0")
        #expect(file.order == "V")
        #expect(file.kind == .draft)
        #expect(file.icons == ["inciting-incident", "crisis"])
        #expect(file.body == [
            .paragraph(Paragraph(runs: [Run("The lamp had been dark for "), Run("eleven", .italic), Run(" years.")])),
            .paragraph(Paragraph(runs: [Run("She climbed anyway. // Too abrupt? Maybe add a beat here.")])),
            .bookmark(Bookmark(id: "b7c1", name: "The storm starts")),
            .paragraph(Paragraph(runs: [Run("Rain came sideways off the water — "), Run("hard", .bold), Run(".")])),
        ])
        #expect(file.outline == [.paragraph(Paragraph("Mara reaches the lighthouse. Finds the logbook. Storm hits."))])
    }

    @Test(arguments: [
        specExample,
        // Note with a hidden outline, extra front matter, empty values.
        """
        ---
        id: n0te01
        title: Research: tides
        parent:
        order: a
        kind: note
        icons:
        synced-by: future-version
        ---
        High tide at 6:12.

        Empty paragraph above, and \\*literal stars\\*.
        <!-- outline -->
        Kept while this is a note.

        """,
        // No outline section; empty body.
        """
        ---
        id: empty1
        title:
        parent:
        order: V
        kind: draft
        icons:
        ---

        """,
        // Prose that looks like markers; bookmark names with odd characters.
        """
        ---
        id: odd123
        title:  leading space kept
        parent:
        order: V
        kind: draft
        icons: climax
        ---
        \\<!-- outline -->
        \\<!-- bookmark ab12: not a bookmark -->
        <!-- bookmark ab12: Name: with colon --> and arrow -->
        <!-- bookmark cd34: -->
        ---
        <!-- outline -->

        """,
    ])
    func canonicalFilesRoundTripExactly(text: String) {
        let file = FileCodec.decode(text, fallbackID: "zzzzzz")
        #expect(bytes(FileCodec.encode(file)) == bytes(text))
    }

    @Test func oddBookmarkNamesParse() {
        let text = """
            ---
            id: odd123
            title: x
            parent:
            order: V
            kind: draft
            icons:
            ---
            <!-- bookmark ab12: Name: with colon --> and arrow -->
            <!-- bookmark cd34: -->
            \\<!-- bookmark ab12: not a bookmark -->

            """
        let file = FileCodec.decode(text, fallbackID: "zzzzzz")
        #expect(file.body == [
            .bookmark(Bookmark(id: "ab12", name: "Name: with colon --> and arrow")),
            .bookmark(Bookmark(id: "cd34", name: "")),
            .paragraph(Paragraph("<!-- bookmark ab12: not a bookmark -->")),
        ])
        #expect(file.outline == nil)
    }

    @Test func fileWithoutFrontMatterKeepsItsText() {
        let file = FileCodec.decode("Just some prose.\r\nSecond line", fallbackID: "abc123")
        #expect(file.id == "abc123")
        #expect(file.title == "abc123")
        #expect(file.kind == .draft)
        #expect(file.body == [.paragraph(Paragraph("Just some prose.")), .paragraph(Paragraph("Second line"))])
    }

    @Test func invalidIDFallsBack() {
        let file = FileCodec.decode("---\nid: ../../etc\ntitle: x\n---\nHi\n", fallbackID: "safe01")
        #expect(file.id == "safe01")
    }

    @Test func newlinesAreSplitIntoParagraphsNotLost() {
        let file = PemeriaFile(
            id: "abc123",
            title: "Two\nlines",
            order: "V",
            body: [.paragraph(Paragraph(runs: [Run("one\ntwo", .italic)]))]
        )
        let decoded = FileCodec.decode(FileCodec.encode(file), fallbackID: "zzzzzz")
        #expect(decoded.title == "Two lines")
        #expect(decoded.body == [
            .paragraph(Paragraph(runs: [Run("one", .italic)])),
            .paragraph(Paragraph(runs: [Run("two", .italic)])),
        ])
    }

    @Test func randomFilesRoundTrip() {
        var rng = SeededGenerator(seed: 3)
        for _ in 0..<2_000 {
            let file = randomFile(using: &rng)
            let text = FileCodec.encode(file)
            let decoded = FileCodec.decode(text, fallbackID: "zzzzzz")
            #expect(decoded == file.canonicalized(), "text: \(text.debugDescription)")
            #expect(bytes(FileCodec.encode(decoded)) == bytes(text))
        }
    }

    @Test func arbitraryTextReachesAFixedPoint() {
        var rng = SeededGenerator(seed: 4)
        let pieces = trickyPieces + ["\n", "\r\n", "\n---\n", "id: x", "title: y", "\n<!-- outline -->\n"]
        for _ in 0..<2_000 {
            let text = (0..<Int.random(in: 0...20, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let once = FileCodec.decode(text, fallbackID: "zzzzzz")
            let twice = FileCodec.decode(FileCodec.encode(once), fallbackID: "zzzzzz")
            #expect(once == twice, "text: \(text.debugDescription)")
        }
    }
}
