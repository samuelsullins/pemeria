@testable import PemeriaCore

/// Deterministic random numbers, so a failing randomized test fails the same way every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Text pieces chosen to hit every special case in the format.
let trickyPieces: [String] = [
    "a", "b", "word", " ", " ", "  ", "\t", "*", "**", "\\", "<", "!", "-", "<!--", "-->",
    "---", ":", ",", "_", "é", "e\u{301}", "\u{301}", "🙂", "👩‍👩‍👧", "“", "”", "’", "—", "…",
    "<!-- outline -->", "<!-- bookmark ab12: x -->", "//", " // note.",
]

let allStyles: [InlineStyle] = [[], .italic, .bold, [.italic, .bold]]

func randomParagraph(using rng: inout SeededGenerator, allowNewlines: Bool = false) -> Paragraph {
    let pieces = allowNewlines ? trickyPieces + ["\n"] : trickyPieces
    let runCount = Int.random(in: 0...6, using: &rng)
    return Paragraph(runs: (0..<runCount).map { _ in
        let text = (0..<Int.random(in: 0...4, using: &rng))
            .map { _ in pieces.randomElement(using: &rng)! }
            .joined()
        return Run(text, allStyles.randomElement(using: &rng)!)
    })
}

func randomBlocks(using rng: inout SeededGenerator) -> [Block] {
    (0..<Int.random(in: 0...6, using: &rng)).map { _ in
        if Int.random(in: 0..<5, using: &rng) == 0 {
            let name = (0..<Int.random(in: 0...3, using: &rng))
                .map { _ in trickyPieces.randomElement(using: &rng)! }
                .joined()
            return .bookmark(Bookmark(id: Bookmark.generateID(avoiding: []), name: name))
        }
        return .paragraph(randomParagraph(using: &rng, allowNewlines: true))
    }
}

func randomFile(using rng: inout SeededGenerator) -> PemeriaFile {
    func randomText() -> String {
        (0..<Int.random(in: 0...3, using: &rng)).map { _ in trickyPieces.randomElement(using: &rng)! }.joined()
    }
    return PemeriaFile(
        id: FileID.generate(avoiding: []),
        title: randomText(),
        parent: Bool.random(using: &rng) ? FileID.generate(avoiding: []) : nil,
        order: OrderKey.between(nil, nil)!,
        kind: Bool.random(using: &rng) ? .draft : .note,
        icons: Bool.random(using: &rng) ? ["crisis", "climax"] : [],
        body: randomBlocks(using: &rng),
        outline: Bool.random(using: &rng) ? randomBlocks(using: &rng) : nil,
        extraFields: Bool.random(using: &rng) ? [ExtraField(key: "future", value: randomText())] : []
    )
}

/// Byte-exact comparison. Swift's `==` on String treats "é" and "e\u{301}" as equal; the file format must not.
func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}
