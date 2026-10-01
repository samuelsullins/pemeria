import AppKit
import PemeriaCore

/// The editor's text view: centers a column of text, routes ⌘I/⌘B, and keeps the
/// clipboard clean in both directions (formatting in = italic/bold only; formatting out =
/// no invisible marker characters).
final class EditorTextView: NSTextView {
    weak var controller: EditorController?

    var maxTextWidth: CGFloat = 680 {
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

    // MARK: Formatting

    @objc func toggleItalic(_ sender: Any?) {
        controller?.toggle(.italic)
    }

    @objc func toggleBold(_ sender: Any?) {
        controller?.toggle(.bold)
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
