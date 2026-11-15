import PemeriaCore
import UIKit

/// Lays out files for reading, in the Mac editor's default typography (SPEC.md §5): New York,
/// a line height of 1.45, justified text, and book-style first-line indents for draft prose.
///
/// Normally shows what the Mac editor shows: comments (dimmed), bookmarks, and each draft's
/// outline after a divider. Read mode shows only the prose, like the Mac's Read mode.
enum ReaderText {
    struct Input: Equatable {
        var files: [PemeriaFile]
        var readMode: Bool
        var fontSize: CGFloat
    }

    static let lineHeight: CGFloat = 1.45
    /// First-line indent, in ems.
    static let indent: CGFloat = 1.5

    static func build(_ input: Input) -> NSAttributedString {
        let fonts = Fonts(size: input.fontSize)
        var pieces: [NSAttributedString] = []

        for (index, file) in input.files.enumerated() {
            // Every file's text starts with its name, as in the Mac editor (Read mode too).
            pieces.append(titleLine(file.title, first: index == 0, fonts: fonts))
            if input.readMode {
                let readable = Comments.strippedParagraphs(of: file.body).compactMap { $0.map(Block.paragraph) }
                pieces.append(prose(readable, indented: file.indents, outline: false, fonts: fonts))
            } else {
                pieces.append(prose(file.body, indented: file.indents, outline: false, fonts: fonts))
                if file.kind == .draft, let outline = file.outline, hasText(outline) {
                    pieces.append(divider(fonts: fonts))
                    pieces.append(prose(outline, indented: false, outline: true, fonts: fonts))
                }
            }
        }

        let result = NSMutableAttributedString()
        for piece in pieces {
            if result.length > 0 {
                // The newline belongs to the paragraph before it, so it takes that paragraph's style.
                let previous = result.attributes(at: result.length - 1, effectiveRange: nil)
                result.append(NSAttributedString(string: "\n", attributes: [
                    .paragraphStyle: previous[.paragraphStyle] ?? NSParagraphStyle.default,
                    .font: previous[.font] ?? fonts.regular,
                ]))
            }
            result.append(piece)
        }
        return result
    }

    // MARK: Pieces

    private static func prose(_ blocks: [Block], indented: Bool, outline: Bool, fonts: Fonts) -> NSAttributedString {
        let text = TextBridge.attributedString(blocks)
        let whole = NSRange(location: 0, length: text.length)
        guard text.length > 0 else { return text }

        text.addAttributes([
            .font: fonts.regular,
            .foregroundColor: outline ? UIColor.secondaryLabel : UIColor.label,
            .paragraphStyle: paragraphStyle(indented: indented, fonts: fonts),
        ], range: whole)
        text.enumerateAttribute(.pemeriaStyle, in: whole) { value, range, _ in
            if let raw = (value as? NSNumber)?.uint8Value {
                text.addAttribute(.font, value: fonts.font(for: InlineStyle(rawValue: raw)), range: range)
            }
        }
        if indented {
            // A file's first paragraph isn't indented, as in a printed book.
            let first = (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            text.addAttribute(.paragraphStyle, value: paragraphStyle(indented: false, fonts: fonts), range: first)
        }

        let commentColor = outline ? UIColor.tertiaryLabel : UIColor.secondaryLabel
        let accent = UIColor(named: "AccentColor") ?? .tintColor
        var lineStart = 0
        let lines = text.string.components(separatedBy: "\n")
        for (line, found) in zip(lines, Comments.annotations(inLines: lines)) {
            for annotation in found {
                let range = NSRange(location: lineStart + annotation.range.location, length: annotation.range.length)
                switch annotation.kind {
                case .comment where annotation.isDone:
                    text.addAttributes([.foregroundColor: UIColor.tertiaryLabel,
                                        .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: range)
                case .comment:
                    text.addAttribute(.foregroundColor, value: commentColor, range: range)
                case .bookmark:
                    text.addAttribute(.foregroundColor, value: accent, range: range)
                }
            }
            lineStart += (line as NSString).length + 1
        }
        return text
    }

    /// Whether an outline has any words (old-style bookmark lines don't count; they're never shown).
    private static func hasText(_ blocks: [Block]) -> Bool {
        blocks.contains { block in
            if case .paragraph(let paragraph) = block { !paragraph.text.allSatisfy(\.isWhitespace) } else { false }
        }
    }

    /// A file's name in large bold type in the text's own typeface, like the Mac's title line.
    private static func titleLine(_ title: String, first: Bool, fonts: Fonts) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.1
        style.paragraphSpacingBefore = first ? 0 : fonts.size * 3
        style.paragraphSpacing = fonts.size * 0.9
        return NSAttributedString(string: title, attributes: [
            .font: fonts.title,
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ])
    }

    /// Headed "Outline", like the Mac's outline divider and every section heading there.
    private static func divider(fonts: Fonts) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = fonts.size * 1.5
        style.paragraphSpacing = fonts.size * 0.5
        return NSAttributedString(string: "Outline", attributes: [
            .font: UIFont.systemFont(ofSize: fonts.size * 0.85, weight: .semibold),
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ])
    }

    private static func paragraphStyle(indented: Bool, fonts: Fonts) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.firstLineHeadIndent = indented ? indent * fonts.size : 0
        // Without indents, a little space is what tells paragraphs apart.
        style.paragraphSpacing = indented ? 0 : fonts.size * 0.5
        // Justified like the Mac's default. Hyphenation keeps a phone's narrow column from
        // opening wide gaps between words; it's display only and never touches the text.
        style.alignment = .justified
        style.hyphenationFactor = 0.7
        return style
    }

    // MARK: Fonts

    struct Fonts {
        let size: CGFloat
        let regular: UIFont
        let title: UIFont
        private let styled: [UInt8: UIFont]

        init(size: CGFloat) {
            self.size = size
            regular = Self.serif(size: size)
            title = Self.serif(size: size * 1.5, traits: .traitBold)
            styled = [
                InlineStyle.italic.rawValue: Self.serif(size: size, traits: .traitItalic),
                InlineStyle.bold.rawValue: Self.serif(size: size, traits: .traitBold),
                InlineStyle([.italic, .bold]).rawValue: Self.serif(size: size, traits: [.traitItalic, .traitBold]),
            ]
        }

        func font(for style: InlineStyle) -> UIFont {
            styled[style.rawValue] ?? regular
        }

        static func serif(size: CGFloat, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
            var descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
            if let serif = descriptor.withDesign(.serif) { descriptor = serif }
            if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) { descriptor = styled }
            return UIFont(descriptor: descriptor, size: size)
        }
    }
}
