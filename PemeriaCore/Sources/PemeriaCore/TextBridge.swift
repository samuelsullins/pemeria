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
/// `.pemeriaStyle` attribute, and each bookmark as one object-replacement character placed
/// inside its paragraph at the bookmark's offset (the editor draws it as an inline tag). Display attributes (fonts, colors, indents) are the
/// editor's business and are ignored here.
public enum TextBridge {
    /// Zero-width "word joiner": the stand-in character for the editor's divider lines.
    public static let markerCharacter: Character = "\u{2060}"
    /// Object replacement character: the stand-in for a bookmark.
    public static let bookmarkCharacter: Character = "\u{FFFC}"
    static let strayScalars: Set<Unicode.Scalar> = ["\u{2060}", "\u{FFFC}"]

    public static func attributedString(_ blocks: [Block]) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        var pending: [Bookmark] = []
        var isFirstLine = true
        for block in Block.canonical(blocks) {
            switch block {
            case .bookmark(let bookmark):
                pending.append(bookmark)
            case .paragraph(let paragraph):
                if !isFirstLine { result.append(NSAttributedString(string: "\n")) }
                isFirstLine = false
                let line = NSMutableAttributedString()
                for run in paragraph.runs {
                    var attributes: [NSAttributedString.Key: Any] = [:]
                    if !run.style.isEmpty { attributes[.pemeriaStyle] = NSNumber(value: run.style.rawValue) }
                    line.append(NSAttributedString(string: run.text, attributes: attributes))
                }
                // Insert from the last bookmark back, so earlier offsets still point at the
                // original text and bookmarks sharing an offset keep their order.
                for bookmark in pending.reversed() {
                    line.insert(marker(for: bookmark), at: min(bookmark.offset, line.length))
                }
                pending = []
                result.append(line)
            }
        }
        return result
    }

    /// The character that stands for a bookmark in the editor.
    public static func marker(for bookmark: Bookmark) -> NSAttributedString {
        NSAttributedString(string: String(bookmarkCharacter), attributes: [.pemeriaBookmark: BookmarkMarker(bookmark)])
    }

    /// Reads blocks back out of editor text. With `emptyMeansNone`, completely empty text gives
    /// no blocks rather than one empty paragraph (used for outlines).
    ///
    /// Never loses words: each bookmark becomes a block before its paragraph, with its offset
    /// counted in the paragraph's own text, and stray marker characters are dropped.
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
        var textLength = 0
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            if let marker = attributes[.pemeriaBookmark] as? BookmarkMarker {
                // One bookmark per character, even if neighbouring markers merged into one run.
                for _ in 0..<runRange.length {
                    var bookmark = marker.bookmark
                    bookmark.offset = textLength
                    bookmarks.append(.bookmark(bookmark))
                }
                return
            }
            let raw = (attributes[.pemeriaStyle] as? NSNumber)?.uint8Value ?? 0
            var piece = (text.string as NSString).substring(with: runRange)
            if piece.unicodeScalars.contains(where: strayScalars.contains) {
                piece = String(String.UnicodeScalarView(piece.unicodeScalars.filter { !strayScalars.contains($0) }))
            }
            textLength += (piece as NSString).length
            runs.append(Run(piece, InlineStyle(rawValue: raw)))
        }
        return bookmarks + [.paragraph(Paragraph(runs: runs).normalized())]
    }
}
