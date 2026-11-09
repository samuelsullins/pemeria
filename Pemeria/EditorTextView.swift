import AppKit
import PemeriaCore

/// The editor's text view: centers a column of text, routes ⌘I/⌘B, and keeps the
/// clipboard clean in both directions (formatting in = italic/bold only; formatting out =
/// no invisible marker characters).
final class EditorTextView: NSTextView {
    weak var controller: EditorController?

    var maxTextWidth: CGFloat = 760 {
        didSet { updateInsets() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let horizontal = max(28, (bounds.width - maxTextWidth) / 2)
        let inset = NSSize(width: horizontal, height: 44)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Cursor height

    /// The cursor as tall as the text, not the whole line: with generous line spacing the system
    /// draws it the full line height, which towers over the letters. The extra spacing sits above
    /// the text, so the trimmed cursor keeps the line's bottom edge.
    private func trimmedCursorRect(_ rect: NSRect) -> NSRect {
        let font = (typingAttributes[.font] as? NSFont) ?? self.font ?? .systemFont(ofSize: 18)
        let height = ceil(font.ascender - font.descender + max(font.leading, 0)) + 1
        guard rect.height > height + 1 else { return rect }
        return NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
    }

    /// Older drawing path, used when the system doesn't use an insertion indicator view.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: trimmedCursorRect(rect), color: color, turnedOn: flag)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        trimInsertionIndicators()
    }

    override func layout() {
        super.layout()
        trimInsertionIndicators()
    }

    /// Current macOS draws the cursor with an insertion indicator view placed by the text view.
    private func trimInsertionIndicators() {
        for case let indicator as NSTextInsertionIndicator in subviews {
            let trimmed = trimmedCursorRect(indicator.frame)
            if trimmed != indicator.frame { indicator.frame = trimmed }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.didBecomeFirstResponder() }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        if controller?.handleClick(at: convert(event.locationInWindow, from: nil)) == true { return }
        super.mouseDown(with: event)
    }

    // MARK: Formatting

    @objc func toggleItalic(_ sender: Any?) {
        controller?.toggle(.italic)
    }

    @objc func toggleBold(_ sender: Any?) {
        controller?.toggle(.bold)
    }

    @objc func insertBookmark(_ sender: Any?) {
        controller?.insertBookmark()
    }

    @objc func toggleCommentDone(_ sender: Any?) {
        controller?.toggleCommentDone()
    }

    @objc func insertComment(_ sender: Any?) {
        controller?.insertComment()
    }

    /// One line is one paragraph, so ⇧Return makes a new paragraph too.
    override func insertLineBreak(_ sender: Any?) {
        insertNewline(sender)
    }

    // MARK: Clipboard

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.rtfd, .rtf, .html, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let incoming = (pboard.readObjects(forClasses: [NSAttributedString.self])?.first as? NSAttributedString)
            ?? pboard.string(forType: .string).map { NSAttributedString(string: $0) }
        guard let incoming, let controller else { return false }
        return controller.insertPasted(incoming)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.rtf, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let controller else { return super.writeSelection(to: pboard, types: types) }
        let copy = controller.cleanCopyOfSelection()
        pboard.clearContents()
        return pboard.writeObjects([copy])
    }

    /// Dragging a selection that spans files would leave a copy behind (the move's delete
    /// half is blocked), so only allow drags inside one file.
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        guard controller?.selectionIsInsideOneSegment ?? false else { return false }
        return super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack)
    }
}
