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
        super.renderingSurfaceBounds.union(CGRect(x: -Self.marginReach, y: 0, width: Self.marginReach, height: layoutFragmentFrame.height))
    }

    /// Where each bookmark's icon and tick go. Several bookmarks on one line step leftward.
    func marks() -> [Mark] {
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
            let iconRight = -Self.iconGap - CGFloat(stack) * (Self.iconSize + 3)
            let icon = CGRect(x: iconRight - Self.iconSize, y: centerY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
            let tick = CGRect(x: x - 0.75, y: baseline - font.capHeight, width: 1.5, height: font.capHeight + 2)
            return Mark(bookmark: bookmark, iconRect: icon, tickRect: tick)
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let accent = NSColor.controlAccentColor
        let symbol = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmark")?
            .withSymbolConfiguration(.init(pointSize: Self.iconSize - 2, weight: .semibold)
                .applying(.init(hierarchicalColor: accent)))
        let marginWidth = (textLayoutManager?.textContainer?.textView?.textContainerInset.width ?? 0)
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

            // The name, to the left of the icon, if it's the only bookmark on its line and fits.
            let sharesLine = marks.contains { $0.iconRect.minY == mark.iconRect.minY && $0.bookmark != mark.bookmark }
            let room = marginWidth - Self.iconGap - Self.iconSize - 14
            guard !sharesLine, room > 40 else { continue }
            let name = NSAttributedString(string: mark.bookmark.name, attributes: [
                .font: Self.nameFont,
                .foregroundColor: accent.withAlphaComponent(0.85),
            ])
            let width = min(name.size().width, room)
            let nameRect = CGRect(x: icon.minX - 5 - width, y: icon.midY - name.size().height / 2,
                                  width: width, height: name.size().height)
            name.draw(with: nameRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
