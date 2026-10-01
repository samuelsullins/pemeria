import Foundation

/// Word counting (SPEC.md §10), matched to Microsoft Word so numbers agree with what agents
/// and publishers see. Word counts every run of non-space characters as one word, so:
///
/// - `well-known` and `word—word` (dash without spaces) are one word;
/// - a spaced dash ` — ` or a lone `…` counts as a word of its own;
/// - numbers count (`1,200` is one word).
///
/// Comments and bookmarks never count.
public enum WordCount {
    /// Words in plain text. Bookmark and marker characters are ignored.
    public static func count(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if TextBridge.strayScalars.contains(scalar) { continue }
            if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Words in part of a paragraph, leaving out comments. Takes the whole paragraph so a
    /// comment is recognised even when `range` starts partway into it.
    public static func count(in range: NSRange, ofLine line: String) -> Int {
        let text = line as NSString
        let range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return 0 }
        var kept = ""
        var cursor = range.location
        for comment in Comments.ranges(in: line) {
            let start = max(comment.location, cursor)
            let end = min(NSMaxRange(comment), NSMaxRange(range))
            guard start < end else { continue }
            if start > cursor { kept += text.substring(with: NSRange(location: cursor, length: start - cursor)) }
            kept += " "
            cursor = end
        }
        if cursor < NSMaxRange(range) {
            kept += text.substring(with: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return count(kept)
    }

    /// Words in a body or outline, leaving out comments.
    public static func count(_ blocks: [Block]) -> Int {
        blocks.reduce(0) { total, block in
            guard case .paragraph(let paragraph) = block else { return total }
            return total + (Comments.stripped(paragraph).map { count($0.text) } ?? 0)
        }
    }
}

/// The numbers behind the word-count bar and its popover. Notes never count.
public struct WordCounts: Hashable, Sendable {
    public var selectedDraft = 0
    public var selectedOutline = 0
    public var totalDraft = 0
    public var totalOutline = 0

    public init(selectedDraft: Int = 0, selectedOutline: Int = 0, totalDraft: Int = 0, totalOutline: Int = 0) {
        self.selectedDraft = selectedDraft
        self.selectedOutline = selectedOutline
        self.totalDraft = totalDraft
        self.totalOutline = totalOutline
    }
}

extension Project {
    /// Word counts for the selected drafts and the whole project. `perFile` returns a draft's
    /// (body, outline) counts; callers can pass a cached version.
    public func wordCounts(selected: Set<FileID>, perFile: (PemeriaFile) -> (body: Int, outline: Int) = Project.wordCount(of:)) -> WordCounts {
        var counts = WordCounts()
        for file in files.values where file.kind == .draft {
            let (body, outline) = perFile(file)
            counts.totalDraft += body
            counts.totalOutline += outline
            if selected.contains(file.id) {
                counts.selectedDraft += body
                counts.selectedOutline += outline
            }
        }
        return counts
    }

    public static func wordCount(of file: PemeriaFile) -> (body: Int, outline: Int) {
        (WordCount.count(file.body), WordCount.count(file.outline ?? []))
    }
}
