import Foundation

extension NSAttributedString.Key {
    /// `InlineStyle.rawValue` as an NSNumber. Absent means plain.
    public static let pemeriaStyle = NSAttributedString.Key("com.samuelsullins.pemeria.style")
    /// A `BookmarkMarker` on the single invisible character that stands for a bookmark.
    public static let pemeriaBookmark = NSAttributedString.Key("com.samuelsullins.pemeria.bookmark")
}

/// Attribute value for a bookmark's placeholder character.
public final class BookmarkMarker: NSObject, @unchecked Sendable {
    public let bookmark: Bookmark

    public init(_ bookmark: Bookmark) {
        self.bookmark = bookmark
    }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? BookmarkMarker)?.bookmark == bookmark
    }

    public override var hash: Int { bookmark.hashValue }
}

/// Converts between blocks and the editor's text: one line per paragraph, italic/bold as a
/// `.pemeriaStyle` attribute, each bookmark as one invisible character on its own line.
/// Display attributes (fonts, colors, indents) are the editor's business and are ignored here.
public enum TextBridge {
    /// Zero-width "word joiner": the stand-in character for bookmarks and other markers.
    public static let markerCharacter: Character = "\u{2060}"
    static let markerScalar: Unicode.Scalar = "\u{2060}"

    public static func attributedString(_ blocks: [Block]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in Block.canonical(blocks).enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            switch block {
            case .paragraph(let paragraph):
                for run in paragraph.runs {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if !run.style.isEmpty { attributes[.pemeriaStyle] = NSNumber(value: run.style.rawValue) }
                    result.append(NSAttributedString(string: run.text, attributes: attributes))
                }
            case .bookmark(let bookmark):
                result.append(NSAttributedString(
                    string: String(markerCharacter),
                    attributes: [.pemeriaBookmark: BookmarkMarker(bookmark)]
                ))
            }
        }
        return result
    }

    /// Reads blocks back out of editor text. With `emptyMeansNone`, completely empty text gives
    /// no blocks rather than one empty paragraph (used for outlines).
    ///
    /// Never loses words: a bookmark that ended up sharing a line with text is kept as its own
    /// block just before that paragraph, and stray marker characters are dropped.
    public static func blocks(from text: NSAttributedString, emptyMeansNone: Bool = false) -> [Block] {
        if text.length == 0 { return emptyMeansNone ? [] : [.paragraph(Paragraph(runs: []))] }

        let string = text.string as NSString
        var blocks: [Block] = []
        var lineStart = 0
        while lineStart <= string.length {
            let newline = string.range(of: "\n", options: .literal, range: NSRange(location: lineStart, length: string.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? string.length : newline.location
            blocks += lineBlocks(text, NSRange(location: lineStart, length: lineEnd - lineStart))
            lineStart = lineEnd + 1
        }
        return blocks
    }

    private static func lineBlocks(_ text: NSAttributedString, _ range: NSRange) -> [Block] {
        var bookmarks: [Block] = []
        var runs: [Run] = []
        var sawMarker = false
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            if let marker = attributes[.pemeriaBookmark] as? BookmarkMarker {
                bookmarks.append(.bookmark(marker.bookmark))
                sawMarker = true
                return
            }
            let raw = (attributes[.pemeriaStyle] as? NSNumber)?.uint8Value ?? 0
            var piece = (text.string as NSString).substring(with: runRange)
            if piece.unicodeScalars.contains(markerScalar) {
                sawMarker = true
                piece = String(String.UnicodeScalarView(piece.unicodeScalars.filter { $0 != markerScalar }))
            }
            runs.append(Run(piece, InlineStyle(rawValue: raw)))
        }
        let paragraph = Paragraph(runs: runs).normalized()
        // A line that held only a bookmark is just the bookmark, not also an empty paragraph.
        if sawMarker && paragraph.runs.isEmpty && !bookmarks.isEmpty { return bookmarks }
        return bookmarks + [.paragraph(paragraph)]
    }
}
