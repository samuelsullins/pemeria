import Foundation
import NaturalLanguage

/// One ⌘F search hit (SPEC.md §12).
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
    /// Where the match is; nil for a file-name match. For a `Mira + Kate` search, the first match.
    public var location: TextLocation?
    /// Set for a bookmark match, so the jump lands on the bookmark itself.
    public var bookmarkID: String?
    /// A short stretch of text around the match.
    public var snippet: String
    /// The match within `snippet` (UTF-16).
    public var matchRange: NSRange
    /// For a `Mira + Kate` search, the other terms' matches that fit in `snippet`.
    public var otherMatchRanges: [NSRange] = []

    /// The text that was matched, as it is in the file.
    public var matchedText: String { (snippet as NSString).substring(with: matchRange) }

    public var id: String {
        let place = location.map { "\($0.inOutline)-\($0.paragraph)-\($0.range.location)" } ?? "name-\(matchRange.location)"
        return "\(kind.rawValue)-\(fileID.rawValue)-\(place)-\(bookmarkID ?? "")"
    }
}

/// How ⌘F matches (SPEC.md §12).
public struct SearchOptions: Hashable, Sendable {
    /// Off: "lamp" finds "Lamp" and "LAMP".
    public var matchCase: Bool
    /// On: "Al" finds "Al" and "Al’s" but not "Also".
    public var wholeWords: Bool
    /// On: "run" also finds "ran" and "running". Whole words only.
    public var wordForms: Bool
    /// Only search these files; nil searches the whole project.
    public var scope: Set<FileID>?

    public init(matchCase: Bool = false, wholeWords: Bool = false, wordForms: Bool = false, scope: Set<FileID>? = nil) {
        self.matchCase = matchCase
        self.wholeWords = wholeWords
        self.wordForms = wordForms
        self.scope = scope
    }
}

/// Each word's dictionary form ("ran" → "run"), remembered per paragraph text so searching
/// with Word Forms on stays quick while typing. Safe to share; one per open project.
public final class WordForms: @unchecked Sendable {
    public struct Word: Sendable {
        public var range: NSRange
        public var lemma: String
    }

    private let lock = NSLock()
    private var cache: [String: [Word]] = [:]
    private let tagger = NLTagger(tagSchemes: [.lemma])

    public init() {}

    /// The words of `text` with their dictionary forms, lowercased.
    public func words(in text: String) -> [Word] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        // Edited paragraphs leave old entries behind; start over now and then.
        if cache.count > 20_000 { cache.removeAll(keepingCapacity: true) }
        tagger.string = text
        var words: [Word] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace, .omitOther]) { tag, range in
            let word = String(text[range])
            words.append(Word(range: NSRange(range, in: text), lemma: (tag?.rawValue ?? word).lowercased()))
            return true
        }
        cache[text] = words
        return words
    }

    /// The dictionary form of one word, lowercased.
    public func lemma(of word: String) -> String {
        words(in: word).first?.lemma ?? word.lowercased()
    }
}

extension Project {
    /// The terms of a `Mira + Kate` search, which finds paragraphs holding all of them.
    /// A plain search is one term.
    public static func searchTerms(_ query: String) -> [String] {
        let query = foldingQuotes(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return query
            .replacingOccurrences(of: #"\s+\+\s*|\s*\+\s+"#, with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Searches everything: file names, drafts, notes, outlines, comments and bookmarks.
    /// Matching ignores accents, full-width forms and curly vs straight quotes, and case unless
    /// `options.matchCase`. `Mira + Kate` finds paragraphs containing every term.
    /// Each kind returns at most `limit` results, in book order.
    public func search(_ query: String, options: SearchOptions = SearchOptions(), wordForms: WordForms? = nil,
                       limit: Int = 50) -> [SearchResult] {
        let terms = Self.searchTerms(query)
        guard !terms.isEmpty else { return [] }
        let matcher = Matcher(options: options, wordForms: options.wordForms ? (wordForms ?? WordForms()) : nil)
        var results: [SearchResult.Kind: [SearchResult]] = [:]

        func add(_ result: SearchResult) {
            if results[result.kind, default: []].count < limit { results[result.kind, default: []].append(result) }
        }

        for id in tree.bookOrder {
            guard let file = files[id], options.scope?.contains(id) ?? true else { continue }
            if terms.count == 1 {
                for match in matcher.ranges(of: terms[0], in: file.title) {
                    add(SearchResult(kind: .fileName, fileID: id, fileTitle: file.title, location: nil,
                                     bookmarkID: nil, snippet: file.title, matchRange: match))
                }
            }

            var sections: [(inOutline: Bool, blocks: [Block])] = [(false, file.body)]
            if file.kind == .draft, let outline = file.outline { sections.append((true, outline)) }
            for (inOutline, blocks) in sections {
                let textKind: SearchResult.Kind = inOutline ? .outline : file.kind == .note ? .note : .draft
                var paragraphIndex = 0
                for block in Block.canonical(blocks) {
                    switch block {
                    case .bookmark(let bookmark):
                        guard terms.count == 1 else { continue }
                        for match in matcher.ranges(of: terms[0], in: bookmark.name) {
                            let location = TextLocation(fileID: id, inOutline: inOutline, paragraph: paragraphIndex,
                                                        range: NSRange(location: bookmark.offset, length: 0))
                            add(SearchResult(kind: .bookmark, fileID: id, fileTitle: file.title, location: location,
                                             bookmarkID: bookmark.id, snippet: bookmark.name, matchRange: match))
                        }
                    case .paragraph(let paragraph):
                        defer { paragraphIndex += 1 }
                        let text = paragraph.text as NSString
                        func location(_ range: NSRange) -> TextLocation {
                            TextLocation(fileID: id, inOutline: inOutline, paragraph: paragraphIndex, range: range)
                        }
                        if terms.count > 1 {
                            // Every term somewhere in the paragraph: one result, led by the earliest match.
                            let found = terms.map { matcher.ranges(of: $0, in: paragraph.text) }
                            guard found.allSatisfy({ !$0.isEmpty }) else { continue }
                            let all = found.flatMap { $0 }.sorted { $0.location < $1.location }
                            let (snippet, snippetMatch) = Self.snippet(of: text, around: all[0])
                            let shift = snippetMatch.location - all[0].location
                            let shown = (snippet as NSString).length - (snippet.hasSuffix("…") ? 1 : 0)
                            let others = all.dropFirst()
                                .map { NSRange(location: $0.location + shift, length: $0.length) }
                                .filter { NSMaxRange($0) <= shown }
                            add(SearchResult(kind: textKind, fileID: id, fileTitle: file.title, location: location(all[0]),
                                             bookmarkID: nil, snippet: snippet, matchRange: snippetMatch, otherMatchRanges: others))
                            continue
                        }
                        let comments = Comments.ranges(in: paragraph.text)
                        for match in matcher.ranges(of: terms[0], in: paragraph.text) {
                            let inComment = comments.contains { NSLocationInRange(match.location, $0) }
                            let (snippet, snippetMatch) = Self.snippet(of: text, around: match)
                            add(SearchResult(kind: inComment ? .comment : textKind, fileID: id, fileTitle: file.title,
                                             location: location(match), bookmarkID: nil, snippet: snippet, matchRange: snippetMatch))
                        }
                    }
                }
            }
        }
        return SearchResult.Kind.allCases.flatMap { results[$0] ?? [] }
    }

    /// Finds one term in a piece of text, following the search options.
    struct Matcher {
        let options: SearchOptions
        let wordForms: WordForms?

        var compareOptions: String.CompareOptions {
            var compare: String.CompareOptions = [.diacriticInsensitive, .widthInsensitive]
            if !options.matchCase { compare.insert(.caseInsensitive) }
            return compare
        }

        /// Where `term` appears in `text`, in order, never overlapping (UTF-16 ranges).
        func ranges(of term: String, in text: String) -> [NSRange] {
            let folded = Project.foldingQuotes(text) as NSString
            // Word forms work word by word; a phrase is matched as typed.
            if let wordForms, !term.contains(where: \.isWhitespace), term.contains(where: \.isLetter) {
                let lemma = wordForms.lemma(of: term)
                return wordForms.words(in: text).compactMap { word in
                    let candidate = folded.substring(with: word.range)
                    let sameWord = candidate.compare(term, options: compareOptions) == .orderedSame
                    let sameLemma = word.lemma.compare(lemma, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                        && (!options.matchCase || candidate.first?.isUppercase == term.first?.isUppercase)
                    return sameWord || sameLemma ? word.range : nil
                }
            }
            var found: [NSRange] = []
            var searchFrom = 0
            while searchFrom < folded.length {
                let match = folded.range(of: term, options: compareOptions,
                                         range: NSRange(location: searchFrom, length: folded.length - searchFrom))
                guard match.location != NSNotFound, match.length > 0 else { break }
                if options.wholeWords, !Self.isWholeWord(match, in: folded) {
                    searchFrom = match.location + 1
                    continue
                }
                found.append(match)
                searchFrom = NSMaxRange(match)
            }
            return found
        }

        /// No letter or digit runs on from either end of the match (where the match itself
        /// starts or ends with one), so "Al" isn't found inside "Also".
        static func isWholeWord(_ match: NSRange, in text: NSString) -> Bool {
            func isWordCharacter(_ index: Int) -> Bool {
                guard index >= 0, index < text.length else { return false }
                let character = text.substring(with: text.rangeOfComposedCharacterSequence(at: index))
                return character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            }
            let first = match.location, last = NSMaxRange(match) - 1
            if isWordCharacter(first), isWordCharacter(first - 1) { return false }
            if isWordCharacter(last), isWordCharacter(last + 1) { return false }
            return true
        }
    }

    // MARK: Replace

    /// Replaces search results with `replacement`: in file names, text (drafts, notes, outlines,
    /// comments) and bookmark names. With `preservingCase`, the replacement follows each match's
    /// capitals ("bob" → "dave", "Bob" → "Dave", "BOB" → "DAVE"). Italic and bold follow the
    /// first letter of the match. Results whose text has changed since the search are skipped.
    /// Returns the changed files and how many matches were replaced.
    public mutating func replace(_ results: [SearchResult], with replacement: String,
                                 preservingCase: Bool) -> (files: [PemeriaFile], count: Int) {
        let replacement = replacement.singleLine
        func replacing(_ matched: String) -> String {
            preservingCase ? Self.matchingCase(of: matched, replacement) : replacement
        }

        var changed: [PemeriaFile] = []
        var count = 0
        let byFile = Dictionary(grouping: results, by: \.fileID)
        for id in tree.bookOrder {
            guard let fileResults = byFile[id], var file = files[id] else { continue }
            let before = file

            // File name: matches from last to first so earlier ranges hold.
            let titleMatches = fileResults.filter { $0.kind == .fileName }.map(\.matchRange).sorted { $0.location > $1.location }
            var title = file.title as NSString
            var lastStart = Int.max
            for range in titleMatches where NSMaxRange(range) <= min(title.length, lastStart) {
                let matched = (fileResults.first { $0.kind == .fileName && $0.matchRange == range }!).matchedText
                guard title.substring(with: range) == matched else { continue }
                title = title.replacingCharacters(in: range, with: replacing(matched)) as NSString
                lastStart = range.location
                count += 1
            }
            if !(title as String).trimmingCharacters(in: .whitespaces).isEmpty { file.title = (title as String).singleLine }

            for inOutline in [false, true] {
                let sectionResults = fileResults.filter { $0.kind != .fileName && $0.location?.inOutline == inOutline }
                guard !sectionResults.isEmpty else { continue }
                guard var blocks = (inOutline ? file.outline : file.body).map(Block.canonical) else { continue }
                count += Self.replace(sectionResults, in: &blocks, using: replacing)
                if inOutline { file.outline = blocks } else { file.body = blocks }
            }

            guard file != before else { continue }
            file.body = Block.canonical(file.body)
            file.outline = file.outline.map(Block.canonical)
            files[id] = file
            changed.append(file)
        }
        return (changed, count)
    }

    /// Applies one file section's results to its canonical blocks. Returns how many were replaced.
    private static func replace(_ results: [SearchResult], in blocks: inout [Block],
                                using replacing: (String) -> String) -> Int {
        // Block index of each paragraph, and of the bookmarks just before it.
        var paragraphBlocks: [Int] = []
        for (index, block) in blocks.enumerated() {
            if case .paragraph = block { paragraphBlocks.append(index) }
        }
        var count = 0

        for result in results where result.kind == .bookmark {
            guard let id = result.bookmarkID,
                  let index = blocks.firstIndex(where: { if case .bookmark(let b) = $0 { b.id == id } else { false } }),
                  case .bookmark(var bookmark) = blocks[index] else { continue }
            let name = bookmark.name as NSString
            guard NSMaxRange(result.matchRange) <= name.length, name.substring(with: result.matchRange) == result.matchedText else { continue }
            bookmark.name = name.replacingCharacters(in: result.matchRange, with: replacing(result.matchedText))
            blocks[index] = .bookmark(bookmark)
            count += 1
        }

        let textResults = results.filter { $0.kind != .bookmark && $0.location != nil }
        for (paragraphIndex, matches) in Dictionary(grouping: textResults, by: { $0.location!.paragraph }) {
            guard paragraphBlocks.indices.contains(paragraphIndex) else { continue }
            let blockIndex = paragraphBlocks[paragraphIndex]
            guard case .paragraph(var paragraph) = blocks[blockIndex] else { continue }
            var bookmarkIndices: [Int] = []
            var index = blockIndex - 1
            while index >= 0, case .bookmark = blocks[index] {
                bookmarkIndices.append(index)
                index -= 1
            }

            var lastStart = Int.max
            for result in matches.sorted(by: { $0.location!.range.location > $1.location!.range.location }) {
                let range = result.location!.range
                let text = paragraph.text as NSString
                guard NSMaxRange(range) <= min(text.length, lastStart),
                      text.substring(with: range) == result.matchedText else { continue }
                let new = replacing(result.matchedText)
                paragraph = paragraph.replacing(range, with: new)
                let delta = (new as NSString).length - range.length
                for bookmarkIndex in bookmarkIndices {
                    guard case .bookmark(var bookmark) = blocks[bookmarkIndex] else { continue }
                    if bookmark.offset >= NSMaxRange(range) {
                        bookmark.offset += delta
                    } else if bookmark.offset > range.location {
                        bookmark.offset = range.location
                    }
                    blocks[bookmarkIndex] = .bookmark(bookmark)
                }
                lastStart = range.location
                count += 1
            }
            blocks[blockIndex] = .paragraph(paragraph)
        }
        return count
    }

    /// `replacement` with the capitals of `matched`: all capitals if the match is ("BOB" →
    /// "DAVE"), otherwise its first letter raised or lowered to match ("bob" → "dave").
    /// Capitals inside the replacement ("McKay") are kept.
    public static func matchingCase(of matched: String, _ replacement: String) -> String {
        let letters = matched.filter(\.isLetter)
        guard let first = letters.first, let index = replacement.firstIndex(where: \.isLetter) else { return replacement }
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return replacement.uppercased() }
        let letter = String(replacement[index])
        let adjusted = first.isUppercase ? letter.uppercased() : letter.lowercased()
        return replacement.replacingCharacters(in: index...index, with: adjusted)
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

extension Paragraph {
    /// The paragraph with `range` (UTF-16) swapped for `text`, which takes the style of the
    /// first character it replaces.
    func replacing(_ range: NSRange, with text: String) -> Paragraph {
        var runs: [Run] = []
        var style: InlineStyle?
        var offset = 0
        for run in self.runs {
            let runText = run.text as NSString
            let runRange = NSRange(location: offset, length: runText.length)
            offset += runText.length
            if style == nil, NSLocationInRange(range.location, runRange) { style = run.style }
            let before = NSIntersectionRange(runRange, NSRange(location: 0, length: range.location))
            if before.length > 0 {
                runs.append(Run(runText.substring(with: NSRange(location: before.location - runRange.location, length: before.length)), run.style))
            }
        }
        runs.append(Run(text, style ?? self.runs.last?.style ?? []))
        offset = 0
        for run in self.runs {
            let runText = run.text as NSString
            let runRange = NSRange(location: offset, length: runText.length)
            offset += runText.length
            let after = NSIntersectionRange(runRange, NSRange(location: NSMaxRange(range), length: Int.max / 2))
            if after.length > 0 {
                runs.append(Run(runText.substring(with: NSRange(location: after.location - runRange.location, length: after.length)), run.style))
            }
        }
        return Paragraph(runs: runs).normalized()
    }
}
