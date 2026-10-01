import Foundation

/// `//` comments (SPEC.md §6). A comment starts with `//` at the start of a line or after
/// whitespace (so `https://` never counts), and runs to the end of the line or through the
/// first `.` `?` `!` or `…`, whichever comes first.
public enum Comments {
    static let terminators: Set<unichar> = [0x2E, 0x3F, 0x21, 0x2026]
    static let slash: unichar = 0x2F

    /// Comment ranges in one line, in UTF-16 offsets.
    public static func ranges(in line: String) -> [NSRange] {
        let string = line as NSString
        var ranges: [NSRange] = []
        var index = 0
        while index + 1 < string.length {
            let startsComment = string.character(at: index) == slash
                && string.character(at: index + 1) == slash
                && (index == 0 || isWhitespace(string.character(at: index - 1)))
            guard startsComment else {
                index += 1
                continue
            }
            var end = index + 2
            while end < string.length {
                let character = string.character(at: end)
                end += 1
                if character == 0x0A { end -= 1; break }
                if terminators.contains(character) { break }
            }
            ranges.append(NSRange(location: index, length: end - index))
            index = end
        }
        return ranges
    }

    /// The paragraph with its comments removed, or nil if nothing but whitespace is left.
    public static func stripped(_ paragraph: Paragraph) -> Paragraph? {
        let ranges = ranges(in: paragraph.text)
        guard !ranges.isEmpty else { return paragraph }
        var runs: [Run] = []
        var offset = 0
        for run in paragraph.runs {
            let text = run.text as NSString
            let runRange = NSRange(location: offset, length: text.length)
            var kept = ""
            var cursor = runRange.location
            for comment in ranges where NSIntersectionRange(comment, runRange).length > 0 {
                let overlap = NSIntersectionRange(comment, runRange)
                if overlap.location > cursor {
                    kept += text.substring(with: NSRange(location: cursor - offset, length: overlap.location - cursor))
                }
                cursor = NSMaxRange(overlap)
            }
            if cursor < NSMaxRange(runRange) {
                kept += text.substring(with: NSRange(location: cursor - offset, length: NSMaxRange(runRange) - cursor))
            }
            runs.append(Run(kept, run.style))
            offset += text.length
        }
        let result = Paragraph(runs: runs).normalized()
        return result.text.allSatisfy(\.isWhitespace) ? nil : result
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return scalar.properties.isWhitespace
    }
}

/// Where something sits inside a file: its body or outline, which line, and where on the line.
public struct TextLocation: Hashable, Sendable {
    public var fileID: FileID
    public var inOutline: Bool
    /// Index into the body's or outline's blocks (one block per line).
    public var line: Int
    /// UTF-16 range within that line.
    public var range: NSRange

    public init(fileID: FileID, inOutline: Bool, line: Int, range: NSRange) {
        self.fileID = fileID
        self.inOutline = inOutline
        self.line = line
        self.range = range
    }
}

public struct CommentEntry: Hashable, Sendable, Identifiable {
    public var location: TextLocation
    /// The comment without its leading `//`.
    public var text: String
    public var id: TextLocation { location }
}

public struct BookmarkEntry: Hashable, Sendable, Identifiable {
    public var location: TextLocation
    public var bookmark: Bookmark
    public var id: TextLocation { location }
}

extension Project {
    /// Comments in the given files' text and outlines, in book order.
    public func comments(in ids: Set<FileID>) -> [CommentEntry] {
        tree.bookOrder.filter(ids.contains).flatMap { id -> [CommentEntry] in
            guard let file = files[id] else { return [] }
            var sections: [(Bool, [Block])] = [(false, file.body)]
            if file.kind == .draft, let outline = file.outline { sections.append((true, outline)) }
            return sections.flatMap { inOutline, blocks in
                blocks.enumerated().flatMap { line, block -> [CommentEntry] in
                    guard case .paragraph(let paragraph) = block else { return [] }
                    let text = paragraph.text as NSString
                    return Comments.ranges(in: paragraph.text).map { range in
                        let body = text.substring(with: NSRange(location: range.location + 2, length: range.length - 2))
                        return CommentEntry(
                            location: TextLocation(fileID: id, inOutline: inOutline, line: line, range: range),
                            text: body.trimmingCharacters(in: .whitespaces)
                        )
                    }
                }
            }
        }
    }

    /// Every bookmark in the project, in book order.
    public func bookmarks() -> [BookmarkEntry] {
        tree.bookOrder.flatMap { id -> [BookmarkEntry] in
            guard let file = files[id] else { return [] }
            var sections: [(Bool, [Block])] = [(false, file.body)]
            if file.kind == .draft, let outline = file.outline { sections.append((true, outline)) }
            return sections.flatMap { inOutline, blocks in
                blocks.enumerated().compactMap { line, block in
                    guard case .bookmark(let bookmark) = block else { return nil }
                    return BookmarkEntry(
                        location: TextLocation(fileID: id, inOutline: inOutline, line: line, range: NSRange(location: 0, length: 1)),
                        bookmark: bookmark
                    )
                }
            }
        }
    }

    /// Renames the bookmark at `location`. Returns the changed file, or nil if it isn't there.
    public mutating func renameBookmark(at location: TextLocation, to name: String) -> PemeriaFile? {
        editBookmark(at: location) { .bookmark(Bookmark(id: $0.id, name: name.singleLine)) }
    }

    /// Removes the bookmark at `location`. Returns the changed file, or nil if it isn't there.
    public mutating func removeBookmark(at location: TextLocation) -> PemeriaFile? {
        editBookmark(at: location) { _ in nil }
    }

    private mutating func editBookmark(at location: TextLocation, _ change: (Bookmark) -> Block?) -> PemeriaFile? {
        guard let file = files[location.fileID] else { return nil }
        var blocks = (location.inOutline ? file.outline : file.body) ?? []
        guard blocks.indices.contains(location.line), case .bookmark(let bookmark) = blocks[location.line] else { return nil }
        if let replacement = change(bookmark) {
            blocks[location.line] = replacement
        } else {
            blocks.remove(at: location.line)
        }
        return location.inOutline
            ? setContent(location.fileID, body: nil, outline: blocks)
            : setContent(location.fileID, body: blocks, outline: nil)
    }

    /// Every bookmark id in use, so new ones can avoid them.
    public var bookmarkIDs: Set<String> {
        Set(bookmarks().map(\.bookmark.id))
    }
}
