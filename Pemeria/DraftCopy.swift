import AppKit
import PemeriaCore

/// Formats draft text for the clipboard (SPEC.md §12): italics and bold as real fonts,
/// book-style first-line indents for drafts, and an empty line between files. The pasteboard
/// gets rich text and plain text from the same string.
enum DraftCopy {
    static let fontSize: CGFloat = 12
    static let indent: CGFloat = 36

    static func attributedString(_ files: [(kind: FileKind, paragraphs: [Paragraph])]) -> NSAttributedString {
        let style = copyStyle()
        var fonts: [InlineStyle: NSFont] = [:]
        func font(_ inline: InlineStyle) -> NSFont {
            if let font = fonts[inline] { return font }
            let font = style.font(for: inline)
            fonts[inline] = font
            return font
        }

        // Every paragraph, with an empty one between files.
        var lines: [(paragraph: Paragraph, indented: Bool)] = []
        for (fileIndex, file) in files.enumerated() {
            if fileIndex > 0 { lines.append((Paragraph(runs: []), false)) }
            for (index, paragraph) in file.paragraphs.enumerated() {
                lines.append((paragraph, file.kind == .draft && index > 0))
            }
        }

        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let start = result.length
            for run in line.paragraph.runs {
                result.append(NSAttributedString(string: run.text, attributes: [.font: font(run.style)]))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font([])]))
            }
            // The style covers the paragraph's own line break, as rich text expects.
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = line.indented ? indent : 0
            result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: start, length: result.length - start))
        }
        return result
    }

    /// The editor's font at a size that pastes sensibly. Mac system fonts (New York, SF) don't
    /// travel to other apps well, so they become their closest common relatives.
    private static func copyStyle() -> EditorStyle {
        var style = EditorStyle.current()
        style.fontSize = Double(fontSize)
        switch style.fontName {
        case "system-serif": style.fontName = "TimesNewRomanPSMT"
        case "system": style.fontName = "HelveticaNeue"
        default: break
        }
        return style
    }
}
