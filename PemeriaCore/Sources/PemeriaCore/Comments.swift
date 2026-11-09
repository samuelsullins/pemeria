import Foundation

/// `//` comments and `#` bookmarks (SPEC.md §6–7): notes to yourself typed right into the text.
///
/// - Each starts at the start of a line or after whitespace, so `https://` and `a#b` never count.
/// - Each runs to the end of its line, or through a backslash `\`, which closes it early.
///   Periods and other punctuation never end one.
/// - **Spanning lines:** one with no `\` on its own line carries on through the following lines
///   if a `\` comes later, before any other `//` or `#`. So an ordinary end-of-line comment can
///   never swallow the prose after it (there's always a next comment, or no `\` at all).
/// - A comment is Done when an `x` follows its slashes: `//x fixed the timeline`.
/// - A `//` inside a bookmark, or a `#` inside a comment, is just part of it.
public enum Comments {
    /// Closes a comment or bookmark before the end of its line (or ends one spanning lines).
    public static let closer: unichar = 0x5C // \
    static let slash: unichar = 0x2F
    static let hash: unichar = 0x23
    static let doneMarks: Set<unichar> = [0x78, 0x58] // x X

    /// The part of a comment or bookmark on one line, in UTF-16 offsets within that line.
    /// One spanning several lines has a part on each.
    public struct Annotation: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case comment
            case bookmark
        }

        public var kind: Kind
        /// Everything on this line: the opening `//` or `#` and any done mark (if they're on
        /// this line), the text, and any closing `\`.
        public var range: NSRange
        /// The words alone, between the opener (and done mark) and the closer. Not trimmed.
        public var textRange: NSRange
        /// A comment marked Done (`//x`). Always false for bookmarks.
        public var isDone: Bool
        /// Ends here with a `\` rather than at the end of the line.
        public var isClosed: Bool
        /// The `//` or `#` is on this line; false on the later lines of one spanning lines.
        public var opensHere: Bool
        /// Carries on to the next line.
        public var continues: Bool
    }

    /// Every comment and bookmark in one line on its own, in order.
    public static func annotations(in line: String) -> [Annotation] {
        annotations(inLines: [line])[0]
    }

    /// Every comment and bookmark in a run of lines (a file's text or outline), line by line.
    /// Comments can span lines, so lines are only read correctly in the company of the others.
    public static func annotations(inLines lines: [String]) -> [[Annotation]] {
        let strings = lines.map { $0 as NSString }
        var result = [[Annotation]](repeating: [], count: strings.count)
        /// The comment or bookmark carried over from the line before, if any.
        var open: (kind: Annotation.Kind, isDone: Bool)?

        for (lineIndex, string) in strings.enumerated() {
            var index = 0
            if let carried = open {
                if let close = firstCloser(in: string, from: 0) {
                    result[lineIndex].append(Annotation(
                        kind: carried.kind, range: NSRange(location: 0, length: close + 1),
                        textRange: NSRange(location: 0, length: close), isDone: carried.isDone,
                        isClosed: true, opensHere: false, continues: false))
                    open = nil
                    index = close + 1
                } else {
                    let whole = NSRange(location: 0, length: string.length)
                    result[lineIndex].append(Annotation(
                        kind: carried.kind, range: whole, textRange: whole, isDone: carried.isDone,
                        isClosed: false, opensHere: false, continues: true))
                    continue
                }
            }

            while index < string.length {
                guard let (kind, openerLength) = opener(in: string, at: index) else {
                    index += 1
                    continue
                }
                var textStart = index + openerLength
                var isDone = false
                if kind == .comment, textStart < string.length, doneMarks.contains(string.character(at: textStart)) {
                    // `//x` alone, `//x fixed`, or `//x\`: an x that's a whole word of its own.
                    let after = textStart + 1
                    if after == string.length || isWhitespace(string.character(at: after)) || string.character(at: after) == closer {
                        isDone = true
                        textStart = after
                    }
                }
                if let close = firstCloser(in: string, from: textStart) {
                    result[lineIndex].append(Annotation(
                        kind: kind, range: NSRange(location: index, length: close + 1 - index),
                        textRange: NSRange(location: textStart, length: close - textStart), isDone: isDone,
                        isClosed: true, opensHere: true, continues: false))
                    index = close + 1
                    continue
                }
                // No closer on this line: to its end, and on through later lines if one is coming.
                let continues = closesOnALaterLine(strings, after: lineIndex)
                result[lineIndex].append(Annotation(
                    kind: kind, range: NSRange(location: index, length: string.length - index),
                    textRange: NSRange(location: textStart, length: string.length - textStart), isDone: isDone,
                    isClosed: false, opensHere: true, continues: continues))
                if continues { open = (kind, isDone) }
                break
            }
        }
        return result
    }

    /// Whether a `\` comes in a later line before any `//` or `#` that would start something new.
    private static func closesOnALaterLine(_ lines: [NSString], after lineIndex: Int) -> Bool {
        for string in lines.dropFirst(lineIndex + 1) {
            let close = firstCloser(in: string, from: 0)
            var index = 0
            while index < string.length, index < (close ?? .max) {
                if opener(in: string, at: index) != nil { return false }
                index += 1
            }
            if close != nil { return true }
        }
        return false
    }

    private static func firstCloser(in string: NSString, from start: Int) -> Int? {
        guard start < string.length else { return nil }
        let found = string.range(of: "\\", options: .literal, range: NSRange(location: start, length: string.length - start))
        return found.location == NSNotFound ? nil : found.location
    }

    /// A `//` or `#` starting at `index` (at the start of the line or after whitespace).
    private static func opener(in string: NSString, at index: Int) -> (Annotation.Kind, Int)? {
        guard index == 0 || isWhitespace(string.character(at: index - 1)) else { return nil }
        let character = string.character(at: index)
        if character == slash, index + 1 < string.length, string.character(at: index + 1) == slash { return (.comment, 2) }
        if character == hash { return (.bookmark, 1) }
        return nil
    }

    /// Ranges of every comment and bookmark in one line on its own.
    public static func ranges(in line: String) -> [NSRange] {
        annotations(in: line).map(\.range)
    }

    /// Paragraphs with their comments and bookmarks removed, one for one; nil where nothing but
    /// whitespace is left. Pass a whole run of paragraphs (a file's text), since comments can
    /// span them. The space before each one goes with it (or, for one that starts the line, the
    /// spaces after it), so no double spaces are left behind.
    public static func stripped(_ paragraphs: [Paragraph]) -> [Paragraph?] {
        let annotations = annotations(inLines: paragraphs.map(\.text))
        return zip(paragraphs, annotations).map { paragraph, found in
            stripped(paragraph, removing: found.map(\.range))
        }
    }

    /// One paragraph on its own, with its comments and bookmarks removed.
    public static func stripped(_ paragraph: Paragraph) -> Paragraph? {
        stripped([paragraph])[0]
    }

    /// Stripped text of one file section's blocks (paragraphs only).
    public static func strippedParagraphs(of blocks: [Block]) -> [Paragraph?] {
        stripped(blocks.compactMap { block -> Paragraph? in
            if case .paragraph(let paragraph) = block { return paragraph }
            return nil
        })
    }

    private static func stripped(_ paragraph: Paragraph, removing found: [NSRange]) -> Paragraph? {
        let text = paragraph.text as NSString
        let ranges = found.map { comment -> NSRange in
            var range = comment
            if range.location > 0 {
                range.location -= 1
                range.length += 1
            } else {
                while NSMaxRange(range) < text.length, isWhitespace(text.character(at: NSMaxRange(range))) {
                    range.length += 1
                }
            }
            return range
        }
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
                cursor = max(cursor, NSMaxRange(overlap))
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

    static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return scalar.properties.isWhitespace
    }
}

/// Where something sits inside a file: its body or outline, which paragraph, and where in it.
public struct TextLocation: Hashable, Sendable {
    public var fileID: FileID
    public var inOutline: Bool
    /// Index among the body's or outline's paragraphs.
    public var paragraph: Int
    /// UTF-16 range within that paragraph's text.
    public var range: NSRange

    public init(fileID: FileID, inOutline: Bool, paragraph: Int, range: NSRange) {
        self.fileID = fileID
        self.inOutline = inOutline
        self.paragraph = paragraph
        self.range = range
    }
}

public struct CommentEntry: Hashable, Sendable, Identifiable {
    /// The whole comment, from `//` through any closing `\`.
    public var location: TextLocation
    /// The comment's words, without `//`, the done mark or the closer.
    public var text: String
    public var isDone: Bool
    public var id: TextLocation { location }
}

public struct BookmarkEntry: Hashable, Sendable, Identifiable {
    /// The whole bookmark, from `#` through any closing `\`.
    public var location: TextLocation
    /// The bookmark's name, without `#` or the closer.
    public var name: String
    public var id: TextLocation { location }
}

extension Project {
    /// A file's body (and, for drafts, outline) paragraphs as (inOutline, paragraphs) pairs.
    private func paragraphSections(of file: PemeriaFile) -> [(inOutline: Bool, paragraphs: [Paragraph])] {
        func paragraphs(_ blocks: [Block]) -> [Paragraph] {
            blocks.compactMap { block -> Paragraph? in
                if case .paragraph(let paragraph) = block { return paragraph }
                return nil
            }
        }
        var sections = [(false, paragraphs(file.body))]
        if file.kind == .draft, let outline = file.outline { sections.append((true, paragraphs(outline))) }
        return sections
    }

    /// Every annotation of one kind in the given files, in book order, each with its words
    /// (joined with spaces when it spans lines) and the part on its first line.
    private func annotations(_ kind: Comments.Annotation.Kind, in ids: [FileID])
        -> [(location: TextLocation, text: String, annotation: Comments.Annotation)] {
        ids.flatMap { id -> [(location: TextLocation, text: String, annotation: Comments.Annotation)] in
            guard let file = files[id] else { return [] }
            return paragraphSections(of: file).flatMap { inOutline, paragraphs in
                var entries: [(location: TextLocation, text: String, annotation: Comments.Annotation)] = []
                for (index, found) in Comments.annotations(inLines: paragraphs.map(\.text)).enumerated() {
                    let text = paragraphs[index].text as NSString
                    for annotation in found where annotation.kind == kind {
                        let words = text.substring(with: annotation.textRange).trimmingCharacters(in: .whitespaces)
                        if annotation.opensHere {
                            entries.append((TextLocation(fileID: id, inOutline: inOutline, paragraph: index, range: annotation.range),
                                            words, annotation))
                        } else if let last = entries.indices.last, !words.isEmpty {
                            entries[last].text += entries[last].text.isEmpty ? words : " " + words
                        }
                    }
                }
                return entries
            }
        }
    }

    /// Comments in the given files' text and outlines, in book order.
    public func comments(in ids: Set<FileID>) -> [CommentEntry] {
        annotations(.comment, in: tree.bookOrder.filter(ids.contains)).map {
            CommentEntry(location: $0.location, text: $0.text, isDone: $0.annotation.isDone)
        }
    }

    /// Every `#` bookmark in the project, in book order.
    public func bookmarks() -> [BookmarkEntry] {
        annotations(.bookmark, in: tree.bookOrder).map { BookmarkEntry(location: $0.location, name: $0.text) }
    }

    /// Marks the comment at `location` Done (`//x`) or not done (`//`). Returns the changed file,
    /// or nil if there's no comment there any more (or it's already that way).
    public mutating func setCommentDone(at location: TextLocation, _ done: Bool) -> PemeriaFile? {
        guard let file = files[location.fileID] else { return nil }
        var blocks = (location.inOutline ? file.outline : file.body) ?? []
        let paragraphIndices = blocks.indices.filter { if case .paragraph = blocks[$0] { true } else { false } }
        guard paragraphIndices.indices.contains(location.paragraph),
              case .paragraph(let paragraph) = blocks[paragraphIndices[location.paragraph]],
              let comment = Comments.annotations(inLines: paragraphIndices.map { index -> String in
                  if case .paragraph(let paragraph) = blocks[index] { return paragraph.text }
                  return ""
              })[location.paragraph].first(where: {
                  $0.kind == .comment && $0.opensHere && $0.range.location == location.range.location
              }),
              comment.isDone != done else { return nil }
        let markLocation = comment.range.location + 2
        let text = paragraph.text as NSString
        // `//fix` needs a space after the x, or it would read as the word "xfix".
        let needsSpace = markLocation < text.length
            && !Comments.isWhitespace(text.character(at: markLocation))
            && text.character(at: markLocation) != Comments.closer
        let changed = done
            ? paragraph.replacing(NSRange(location: markLocation, length: 0), with: needsSpace ? "x " : "x")
            : paragraph.replacing(NSRange(location: markLocation, length: 1), with: "")
        blocks[paragraphIndices[location.paragraph]] = .paragraph(changed)
        return location.inOutline
            ? setContent(location.fileID, body: nil, outline: blocks)
            : setContent(location.fileID, body: blocks, outline: nil)
    }
}
