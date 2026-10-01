import Foundation

/// Inline formatting a run of text can carry.
public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let italic = InlineStyle(rawValue: 1 << 0)
    public static let bold = InlineStyle(rawValue: 1 << 1)
}

/// A stretch of text with one style.
public struct Run: Hashable, Sendable {
    public var text: String
    public var style: InlineStyle

    public init(_ text: String, _ style: InlineStyle = []) {
        self.text = text
        self.style = style
    }
}

/// One paragraph: one line in the file. Never contains a newline once normalized.
public struct Paragraph: Hashable, Sendable {
    public var runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs
    }

    public init(_ text: String, _ style: InlineStyle = []) {
        self.runs = [Run(text, style)]
    }

    public var text: String { runs.map(\.text).joined() }

    /// The canonical form: no empty runs, neighbouring runs with the same style merged,
    /// and whitespace at the edges of italic/bold stretches made plain (so the file reads
    /// `*word* ` rather than `*word *`). Characters are never changed, only styles.
    ///
    /// Works on Unicode scalars rather than Characters, so an accent can never merge
    /// with a neighbouring formatting mark.
    public func normalized() -> Paragraph {
        var scalars: [(scalar: Unicode.Scalar, style: InlineStyle)] = runs.flatMap { run in
            run.text.unicodeScalars.map { ($0, run.style) }
        }

        for bit in [InlineStyle.italic, .bold] {
            var i = 0
            while i < scalars.count {
                guard scalars[i].style.contains(bit) else { i += 1; continue }
                var end = i
                while end < scalars.count, scalars[end].style.contains(bit) { end += 1 }
                var start = i
                while start < end, scalars[start].scalar.properties.isWhitespace {
                    scalars[start].style.remove(bit)
                    start += 1
                }
                var last = end - 1
                while last >= start, scalars[last].scalar.properties.isWhitespace {
                    scalars[last].style.remove(bit)
                    last -= 1
                }
                i = end
            }
        }

        var merged: [Run] = []
        for (scalar, style) in scalars {
            if let lastIndex = merged.indices.last, merged[lastIndex].style == style {
                merged[lastIndex].text.unicodeScalars.append(scalar)
            } else {
                merged.append(Run(String(scalar), style))
            }
        }
        return Paragraph(runs: merged)
    }
}

/// A named marker on a line. Drawn as a labeled dotted line above the line it marks.
public struct Bookmark: Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// A new random bookmark id that isn't in `existing`.
    public static func generateID<S: Sequence>(avoiding existing: S) -> String where S.Element == String {
        Identifier.generate(length: 4, avoiding: Set(existing))
    }
}

/// One line of a file's body or outline.
public enum Block: Hashable, Sendable {
    case paragraph(Paragraph)
    case bookmark(Bookmark)

    /// The canonical form of a list of blocks: paragraphs normalized and split at any
    /// newlines they contain, newlines in bookmark names replaced with spaces.
    public static func canonical(_ blocks: [Block]) -> [Block] {
        blocks.flatMap { block -> [Block] in
            switch block {
            case .bookmark(let bookmark):
                var id = bookmark.id.lowercased().filter { Identifier.alphabet.contains($0) }
                if id.isEmpty { id = "0" }
                return [.bookmark(Bookmark(id: String(id.prefix(64)), name: bookmark.name.singleLine))]
            case .paragraph(let paragraph):
                return paragraph.splitAtNewlines().map { .paragraph($0.normalized()) }
            }
        }
    }
}

public enum FileKind: String, Hashable, Sendable {
    case draft
    case note
}

/// A front-matter line Pemeria doesn't recognize, kept so it survives a save.
public struct ExtraField: Hashable, Sendable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One sidebar item: a draft or a note, as stored in `files/<id>.md`.
public struct PemeriaFile: Hashable, Sendable, Identifiable {
    public var id: FileID
    public var title: String
    public var parent: FileID?
    public var order: String
    public var kind: FileKind
    /// Icon ids from the project's icon definitions.
    public var icons: [String]
    public var body: [Block]
    /// nil when the file has no outline section at all. Notes keep a draft's outline
    /// here (hidden) so converting back and forth never loses it.
    public var outline: [Block]?
    public var extraFields: [ExtraField]

    public init(
        id: FileID,
        title: String,
        parent: FileID? = nil,
        order: String,
        kind: FileKind = .draft,
        icons: [String] = [],
        body: [Block] = [.paragraph(Paragraph(runs: []))],
        outline: [Block]? = [],
        extraFields: [ExtraField] = []
    ) {
        self.id = id
        self.title = title
        self.parent = parent
        self.order = order
        self.kind = kind
        self.icons = icons
        self.body = body
        self.outline = outline
        self.extraFields = extraFields
    }

    /// The form this file takes after a save and reload. Saving never changes any
    /// characters of the prose; it only tidies styles and anything that can't fit on one line.
    public func canonicalized() -> PemeriaFile {
        var copy = self
        copy.title = title.singleLine
        copy.order = order.singleLine
        copy.icons = icons
            .map { $0.singleLine.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        copy.body = Block.canonical(body)
        copy.outline = outline.map(Block.canonical)
        copy.extraFields = extraFields.compactMap { field in
            let key = field.key.singleLine.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !FileCodec.knownKeys.contains(key) else { return nil }
            return ExtraField(key: key, value: field.value.singleLine)
        }
        return copy
    }
}

extension Paragraph {
    func splitAtNewlines() -> [Paragraph] {
        var paragraphs = [Paragraph(runs: [])]
        for run in runs {
            var current = ""
            for character in run.text {
                if character.isNewline {
                    paragraphs[paragraphs.count - 1].runs.append(Run(current, run.style))
                    paragraphs.append(Paragraph(runs: []))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            paragraphs[paragraphs.count - 1].runs.append(Run(current, run.style))
        }
        return paragraphs
    }
}

extension String {
    var singleLine: String {
        String(map { $0.isNewline ? " " : $0 })
    }
}
