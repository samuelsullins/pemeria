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
        // The font the line is actually shown in. The typing attributes lag behind the cursor
        // for a moment and can hold a marker line's font, which made a stubby cursor.
        let font = controller?.displayFont(at: selectedRange().location)
            ?? (typingAttributes[.font] as? NSFont) ?? self.font ?? .systemFont(ofSize: 18)
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

    // MARK: Select All

    /// ⌘A selects the file's text but not its title; in a title, just the title.
    override func selectAll(_ sender: Any?) {
        if let range = controller?.selectAllRange {
            setSelectedRange(range)
        } else {
            super.selectAll(sender)
        }
    }

    // MARK: Typewriter scrolling

    /// Typewriter scrolling (Settings): as you type or move with the keys, the text moves up
    /// past the cursor's line rather than the cursor working its way down the window. By
    /// default the line stays wherever it was when you started typing; it can be kept in the
    /// middle instead, or turned off.
    private enum Typewriter: String {
        case inPlace, middle, off
    }

    private var typewriter: Typewriter {
        Typewriter(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.typewriter) ?? "") ?? .inPlace
    }

    /// Where the cursor's line sits, down from the top of the view, while typing in place.
    /// Taken when you start typing; let go when you click or scroll, so it's taken afresh.
    private var anchorOffset: CGFloat?

    /// Room under the last line, so it too can come up the window.
    func updateOverscroll() {
        guard let scroll = enclosingScrollView else { return }
        let bottom = typewriter == .off ? 0 : (scroll.contentView.frame.height / 2).rounded()
        guard scroll.contentInsets.bottom != bottom else { return }
        // The view changed size (or the setting changed): take the line's place afresh.
        anchorOffset = nil
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        // The scroller still runs the full height.
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -bottom, right: 0)
    }

    override func keyDown(with event: NSEvent) {
        if typewriter == .inPlace, anchorOffset == nil, let caret = cursorLineRect(), let clip = enclosingScrollView?.contentView {
            let offset = caret.midY - clip.bounds.minY
            // Only while the cursor is on screen; otherwise this key brings it back as usual.
            if offset >= 0, offset <= clip.bounds.height { anchorOffset = offset }
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        anchorOffset = nil
        super.scrollWheel(with: event)
    }

    /// The text view asks for this after typing and after moving with the keys; keep the
    /// cursor's line where typewriter scrolling wants it then. Clicks and everything else
    /// scroll as usual.
    override func scrollRangeToVisible(_ range: NSRange) {
        let target: CGFloat? = switch typewriter {
        case .off: nil
        case .middle: enclosingScrollView.map { $0.contentView.bounds.height / 2 }
        case .inPlace: anchorOffset
        }
        guard let target, range.length == 0, range == selectedRange(),
              NSApp.currentEvent?.type == .keyDown, keepCursorLine(at: target) else {
            super.scrollRangeToVisible(range)
            return
        }
    }

    /// The cursor's line, in this view's coordinates.
    private func cursorLineRect() -> NSRect? {
        guard let window else { return nil }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        guard screenRect != .zero else { return nil }
        return convert(window.convertFromScreen(screenRect), from: nil)
    }

    /// Scrolls so the cursor's line sits `offset` down from the top of the view (as near as
    /// the ends of the text allow). False if the cursor couldn't be found.
    private func keepCursorLine(at offset: CGFloat) -> Bool {
        guard let scroll = enclosingScrollView, let caret = cursorLineRect() else { return false }
        let clip = scroll.contentView
        let visible = clip.bounds
        let insets = scroll.contentInsets
        let highest = -insets.top
        let lowest = max(highest, bounds.height + insets.bottom - visible.height)
        let y = min(max(caret.midY - offset, highest), lowest)
        guard abs(y - visible.minY) > 0.5 else { return true }
        clip.scroll(to: NSPoint(x: visible.minX, y: y))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateOverscroll()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.didBecomeFirstResponder() }
        return became
    }

    override func mouseDown(with event: NSEvent) {
        anchorOffset = nil
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
