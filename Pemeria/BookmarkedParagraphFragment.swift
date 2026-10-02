import AppKit
import PemeriaCore

/// A paragraph that contains bookmarks. Draws the text as usual, then for each bookmark a
/// faint accent tick at its exact spot and a bookmark icon (with the name, if there's room)
/// in the left margin beside that line (SPEC.md §7). Clicking the icon is handled by the editor.
final class BookmarkedParagraphFragment: NSTextLayoutFragment {
    struct Mark {
        let bookmark: Bookmark
        /// Clickable icon in the margin, relative to the fragment's origin.
        let iconRect: CGRect
        /// Thin tick at the bookmark's spot in the text, relative to the fragment's origin.
        let tickRect: CGRect
        /// The name, left of the icon, when it's the only bookmark on its line and the margin has room.
        var labelRect: CGRect?

        /// Everything that opens the bookmark's popup when clicked: the icon and its name.
        var clickRect: CGRect { labelRect.map { iconRect.union($0) } ?? iconRect }
    }

    /// Bookmarks in this paragraph, with their character index in the paragraph.
    let bookmarks: [(index: Int, bookmark: Bookmark)]

    static let iconSize: CGFloat = 13
    /// The icon's right edge sits this far left of the text column.
    static let iconGap: CGFloat = 8
    /// How far into the margin drawing may reach.
    static let marginReach: CGFloat = 220
    static let nameFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    init(textElement: NSTextElement, range: NSTextRange?, bookmarks: [(index: Int, bookmark: Bookmark)]) {
        self.bookmarks = bookmarks
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var renderingSurfaceBounds: CGRect {
        let reach = Self.marginReach + layoutFragmentFrame.minX
        return super.renderingSurfaceBounds.union(CGRect(x: -reach, y: 0, width: reach, height: layoutFragmentFrame.height))
    }

    /// Where each bookmark's icon and tick go. Several bookmarks on one line step leftward.
    /// Icons are placed against the text column's edge, not the fragment's: TextKit shifts a
    /// one-line paragraph's fragment (a blank line, say) by its first-line indent.
    func marks() -> [Mark] {
        let columnEdge = (textLayoutManager?.textContainer?.lineFragmentPadding ?? 0) - layoutFragmentFrame.minX
        guard let paragraph = textElement as? NSTextParagraph else { return [] }
        let text = paragraph.attributedString
        var perLine: [Int: Int] = [:]
        let lines = textLineFragments
        return bookmarks.compactMap { index, bookmark in
            // A blank line holding only a bookmark still has one line fragment; fall back to it.
            guard let (lineIndex, line) = lines.enumerated().first(where: {
                NSLocationInRange(index, $0.element.characterRange) || index == NSMaxRange($0.element.characterRange)
            }) ?? lines.enumerated().first else { return nil }
            let font = (index < text.length ? text.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil)
                ?? NSFont.systemFont(ofSize: 16)
            let bounds = line.typographicBounds
            let baseline = bounds.minY + line.glyphOrigin.y
            let centerY = baseline - font.xHeight / 2
            let x = bounds.minX + line.locationForCharacter(at: index).x

            let stack = perLine[lineIndex, default: 0]
            perLine[lineIndex] = stack + 1
            let iconRight = columnEdge - Self.iconGap - CGFloat(stack) * (Self.iconSize + 3)
            let icon = CGRect(x: iconRight - Self.iconSize, y: centerY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
            let tick = CGRect(x: x - 0.75, y: baseline - font.capHeight, width: 1.5, height: font.capHeight + 2)
            return Mark(bookmark: bookmark, iconRect: icon, tickRect: tick)
        }
        .withLabels(marginWidth: textLayoutManager?.textContainer?.textView?.textContainerInset.width ?? 0)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let accent = Theme.accent
        let symbol = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmark")?
            .withSymbolConfiguration(.init(pointSize: Self.iconSize - 2, weight: .semibold)
                .applying(.init(hierarchicalColor: accent)))
        let marks = marks()

        // On a line with no words, the margin icon says it all; skip the tick.
        let hasWords = (textElement as? NSTextParagraph)?.attributedString.string
            .contains { !$0.isWhitespace && $0 != TextBridge.bookmarkCharacter } ?? true

        for mark in marks {
            if hasWords {
                let tick = mark.tickRect.offsetBy(dx: point.x, dy: point.y)
                accent.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: tick, xRadius: 0.75, yRadius: 0.75).fill()
            }

            let icon = mark.iconRect.offsetBy(dx: point.x, dy: point.y)
            symbol?.draw(in: icon)

            guard let label = mark.labelRect else { continue }
            Self.name(mark.bookmark, color: accent.withAlphaComponent(0.85))
                .draw(with: label.offsetBy(dx: point.x, dy: point.y), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    static func name(_ bookmark: Bookmark, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: bookmark.name, attributes: [.font: nameFont, .foregroundColor: color])
    }
}

private extension Array where Element == BookmarkedParagraphFragment.Mark {
    /// Gives each mark that's alone on its line a name label, if the margin has room.
    func withLabels(marginWidth: CGFloat) -> [Element] {
        let room = marginWidth - BookmarkedParagraphFragment.iconGap - BookmarkedParagraphFragment.iconSize - 14
        return map { mark in
            var mark = mark
            let sharesLine = contains { $0.iconRect.minY == mark.iconRect.minY && $0.bookmark != mark.bookmark }
            guard !sharesLine, room > 40 else { return mark }
            let size = BookmarkedParagraphFragment.name(mark.bookmark).size()
            let width = Swift.min(size.width, room)
            mark.labelRect = CGRect(x: mark.iconRect.minX - 5 - width, y: mark.iconRect.midY - size.height / 2,
                                    width: width, height: size.height)
            return mark
        }
    }
}
