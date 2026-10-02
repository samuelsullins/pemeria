import Foundation

/// One ⌘K search hit (SPEC.md §12).
public struct SearchResult: Hashable, Sendable, Identifiable {
    /// What was matched. Results are grouped in this order.
    public enum Kind: Int, CaseIterable, Comparable, Sendable {
        case fileName, draft, note, outline, comment, bookmark

        public var title: String {
            switch self {
            case .fileName: "Files"
            case .draft: "Drafts"
            case .note: "Notes"
            case .outline: "Outlines"
            case .comment: "Comments"
            case .bookmark: "Bookmarks"
            }
        }

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var fileID: FileID
    public var fileTitle: String
    /// Where the match is; nil for a file-name match.
    public var location: TextLocation?
    /// Set for a bookmark match, so the jump lands on the bookmark itself.
    public var bookmarkID: String?
    /// A short stretch of text around the match.
    public var snippet: String
    /// The match within `snippet` (UTF-16).
    public var matchRange: NSRange

    public var id: String {
        let place = location.map { "\($0.inOutline)-\($0.paragraph)-\($0.range.location)" } ?? "name"
        return "\(kind.rawValue)-\(fileID.rawValue)-\(place)-\(bookmarkID ?? "")"
    }
}

extension Project {
    /// Searches everything: file names, drafts, notes, outlines, comments and bookmarks.
    /// Matching ignores case, accents, full-width forms and curly vs straight quotes.
    /// Each kind returns at most `limit` results, in book order.
    public func search(_ query: String, limit: Int = 50) -> [SearchResult] {
        let query = Self.foldingQuotes(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var results: [SearchResult.Kind: [SearchResult]] = [:]

        func add(_ result: SearchResult) {
            if results[result.kind, default: []].count < limit { results[result.kind, default: []].append(result) }
        }

        for id in tree.bookOrder {
            guard let file = files[id] else { continue }
            let title = Self.foldingQuotes(file.title) as NSString
            let titleMatch = title.range(of: query, options: options)
            if titleMatch.location != NSNotFound {
                add(SearchResult(kind: .fileName, fileID: id, fileTitle: file.title, location: nil,
                                 bookmarkID: nil, snippet: file.title, matchRange: titleMatch))
            }

            var sections: [(inOutline: Bool, blocks: [Block])] = [(false, file.body)]
            if file.kind == .draft, let outline = file.outline { sections.append((true, outline)) }
            for (inOutline, blocks) in sections {
                var paragraphIndex = 0
                for block in Block.canonical(blocks) {
                    switch block {
                    case .bookmark(let bookmark):
                        let match = (Self.foldingQuotes(bookmark.name) as NSString).range(of: query, options: options)
                        guard match.location != NSNotFound else { continue }
                        let location = TextLocation(fileID: id, inOutline: inOutline, paragraph: paragraphIndex,
                                                    range: NSRange(location: bookmark.offset, length: 0))
                        add(SearchResult(kind: .bookmark, fileID: id, fileTitle: file.title, location: location,
                                         bookmarkID: bookmark.id, snippet: bookmark.name, matchRange: match))
                    case .paragraph(let paragraph):
                        defer { paragraphIndex += 1 }
                        let text = paragraph.text as NSString
                        let folded = Self.foldingQuotes(paragraph.text) as NSString
                        let comments = Comments.ranges(in: paragraph.text)
                        var searchFrom = 0
                        while searchFrom < text.length {
                            let match = folded.range(of: query, options: options,
                                                   range: NSRange(location: searchFrom, length: text.length - searchFrom))
                            guard match.location != NSNotFound else { break }
                            searchFrom = NSMaxRange(match)
                            let inComment = comments.contains { NSLocationInRange(match.location, $0) }
                            let kind: SearchResult.Kind = inComment ? .comment : inOutline ? .outline : file.kind == .note ? .note : .draft
                            let (snippet, snippetMatch) = Self.snippet(of: text, around: match)
                            add(SearchResult(kind: kind, fileID: id, fileTitle: file.title,
                                             location: TextLocation(fileID: id, inOutline: inOutline, paragraph: paragraphIndex, range: match),
                                             bookmarkID: nil, snippet: snippet, matchRange: snippetMatch))
                        }
                    }
                }
            }
        }
        return SearchResult.Kind.allCases.flatMap { results[$0] ?? [] }
    }

    /// Curly quotes and apostrophes as straight ones, so "don't" finds "don’t". Each swap is
    /// one UTF-16 unit for one, so ranges found in the result hold in the original.
    static func foldingQuotes(_ text: String) -> String {
        guard text.contains(where: { "‘’‚‛“”„‟".contains($0) }) else { return text }
        return String(text.map { character -> Character in
            switch character {
            case "‘", "’", "‚", "‛": "'"
            case "“", "”", "„", "‟": "\""
            default: character
            }
        })
    }

    /// About `before` characters of context before the match and enough after to fill
    /// `length`, cut at spaces, with ellipses where text was left out.
    static func snippet(of text: NSString, around match: NSRange, before: Int = 32, length: Int = 110) -> (String, NSRange) {
        var start = max(0, match.location - before)
        if start > 0 {
            // Start at the beginning of a word.
            let space = text.range(of: " ", options: .literal, range: NSRange(location: start, length: match.location - start))
            if space.location != NSNotFound { start = space.location + 1 }
        }
        var end = min(text.length, max(NSMaxRange(match), start + length))
        if end < text.length {
            let space = text.range(of: " ", options: [.literal, .backwards],
                                   range: NSRange(location: NSMaxRange(match), length: end - NSMaxRange(match)))
            if space.location != NSNotFound { end = space.location }
        }
        start = text.rangeOfComposedCharacterSequence(at: start).location
        if end < text.length { end = text.rangeOfComposedCharacterSequence(at: end).location }
        let prefix = start > 0 ? "…" : ""
        let suffix = end < text.length ? "…" : ""
        let body = text.substring(with: NSRange(location: start, length: end - start))
        let range = NSRange(location: (prefix as NSString).length + match.location - start, length: match.length)
        return (prefix + body + suffix, range)
    }
}
