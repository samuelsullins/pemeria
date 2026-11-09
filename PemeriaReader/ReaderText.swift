import PemeriaCore
import UIKit

/// Lays out files for reading, in the Mac editor's default typography (SPEC.md §5): New York,
/// a line height of 1.45, and book-style first-line indents for draft prose. Unlike the Mac's
/// default, text isn't justified.
///
/// Normally shows what the Mac editor shows: comments (dimmed), bookmarks, and each draft's
/// outline after a divider. Read mode shows only the prose, like the Mac's Read mode.
enum ReaderText {
    struct Input: Equatable {
        var files: [PemeriaFile]
        var icons: [IconDefinition]
        var readMode: Bool
        var fontSize: CGFloat
    }

    static let lineHeight: CGFloat = 1.45
    /// First-line indent, in ems.
    static let indent: CGFloat = 1.5

    static func build(_ input: Input) -> NSAttributedString {
        let fonts = Fonts(size: input.fontSize)
        let definitions = Dictionary(input.icons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pieces: [NSAttributedString] = []

        for (index, file) in input.files.enumerated() {
            if input.files.count > 1 {
                let icons = file.icons.compactMap { definitions[$0] }.prefix(Project.maxIconsPerFile)
                pieces.append(header(file.title, icons: Array(icons), first: index == 0, fonts: fonts))
            }
            if input.readMode {
                let readable = Comments.strippedParagraphs(of: file.body).compactMap { $0.map(Block.paragraph) }
                pieces.append(prose(readable, indented: file.indents, outline: false, fonts: fonts))
            } else {
                pieces.append(prose(file.body, indented: file.indents, outline: false, fonts: fonts))
                if file.kind == .draft, let outline = file.outline,
                   outline.contains(where: { if case .paragraph(let p) = $0 { !p.text.isEmpty } else { true } }) {
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

    private static func header(_ title: String, icons: [IconDefinition], first: Bool, fonts: Fonts) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = first ? 0 : fonts.size * 2.5
        style.paragraphSpacing = fonts.size * 0.75
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: fonts.title,
            .foregroundColor: UIColor.label,
            .paragraphStyle: style,
        ])
        for icon in icons {
            let configuration = UIImage.SymbolConfiguration(pointSize: fonts.size * 0.75, weight: .semibold)
            guard let image = UIImage(systemName: icon.symbol, withConfiguration: configuration)?
                .withTintColor(icon.uiColor, renderingMode: .alwaysOriginal) else { continue }
            result.append(NSAttributedString(string: " ", attributes: [.font: fonts.title, .paragraphStyle: style]))
            let glyph = NSMutableAttributedString(attachment: NSTextAttachment(image: image))
            glyph.addAttributes([.font: fonts.title, .paragraphStyle: style], range: NSRange(location: 0, length: glyph.length))
            result.append(glyph)
        }
        return result
    }

    private static func divider(fonts: Fonts) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacingBefore = fonts.size * 1.5
        style.paragraphSpacing = fonts.size * 0.75
        return NSAttributedString(string: "OUTLINE", attributes: [
            .font: UIFont.systemFont(ofSize: fonts.size * 0.65, weight: .semibold),
            .kern: fonts.size * 0.1,
            .foregroundColor: UIColor.tertiaryLabel,
            .paragraphStyle: style,
        ])
    }

    private static func paragraphStyle(indented: Bool, fonts: Fonts) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.firstLineHeadIndent = indented ? indent * fonts.size : 0
        // Without indents, a little space is what tells paragraphs apart.
        style.paragraphSpacing = indented ? 0 : fonts.size * 0.5
        // Ragged right: a phone's narrow column justifies into wide gaps between words.
        style.alignment = .natural
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
            title = Self.serif(size: size * 1.2, traits: .traitBold)
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
