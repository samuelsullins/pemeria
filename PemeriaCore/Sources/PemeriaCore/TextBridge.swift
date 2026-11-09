import Foundation

extension NSAttributedString.Key {
    /// `InlineStyle.rawValue` as an NSNumber. Absent means plain.
    public static let pemeriaStyle = NSAttributedString.Key("com.samuelsullins.pemeria.style")
}

/// Converts between blocks and the editor's text: one line per paragraph, with italic/bold as a
/// `.pemeriaStyle` attribute. Display attributes (fonts, colors, indents) are the editor's
/// business and are ignored here.
///
/// Bookmarks are `#` text inside paragraphs now (SPEC.md §7). Old-style bookmark lines
/// (`Block.bookmark`) are left out of the editor, so they're dropped when the file next saves.
public enum TextBridge {
    /// Zero-width "word joiner": the stand-in character for the editor's divider lines.
    public static let markerCharacter: Character = "\u{2060}"
    static let strayScalars: Set<Unicode.Scalar> = ["\u{2060}", "\u{FFFC}"]

    public static func attributedString(_ blocks: [Block]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var isFirstLine = true
        for block in Block.canonical(blocks) {
            guard case .paragraph(let paragraph) = block else { continue }
            if !isFirstLine { result.append(NSAttributedString(string: "\n")) }
            isFirstLine = false
            for run in paragraph.runs {
                var attributes: [NSAttributedString.Key: Any] = [:]
                if !run.style.isEmpty { attributes[.pemeriaStyle] = NSNumber(value: run.style.rawValue) }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return result
    }

    /// Reads blocks back out of editor text. With `emptyMeansNone`, completely empty text gives
    /// no blocks rather than one empty paragraph (used for outlines).
    ///
    /// Never loses words: stray marker characters are dropped, everything else is kept.
    public static func blocks(from text: NSAttributedString, emptyMeansNone: Bool = false) -> [Block] {
        if text.length == 0 { return emptyMeansNone ? [] : [.paragraph(Paragraph(runs: []))] }

        let string = text.string as NSString
        var blocks: [Block] = []
        var lineStart = 0
        while lineStart <= string.length {
            let newline = string.range(of: "\n", options: .literal, range: NSRange(location: lineStart, length: string.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? string.length : newline.location
            blocks.append(.paragraph(paragraph(text, NSRange(location: lineStart, length: lineEnd - lineStart))))
            lineStart = lineEnd + 1
        }
        return blocks
    }

    private static func paragraph(_ text: NSAttributedString, _ range: NSRange) -> Paragraph {
        var runs: [Run] = []
        text.enumerateAttribute(.pemeriaStyle, in: range) { value, runRange, _ in
            let raw = (value as? NSNumber)?.uint8Value ?? 0
            var piece = (text.string as NSString).substring(with: runRange)
            if piece.unicodeScalars.contains(where: strayScalars.contains) {
                piece = String(String.UnicodeScalarView(piece.unicodeScalars.filter { !strayScalars.contains($0) }))
            }
            runs.append(Run(piece, InlineStyle(rawValue: raw)))
        }
        return Paragraph(runs: runs).normalized()
    }
}
