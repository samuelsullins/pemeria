import AppKit

/// The small popup ⌘D opens at the cursor: type a name, Return to add, Esc to cancel.
final class BookmarkNamePrompt: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    /// Keeps the open prompt alive until its popover closes.
    private static var current: BookmarkNamePrompt?

    private let field = NSTextField()
    private let popover = NSPopover()
    private var onCommit: ((String) -> Void)?

    static func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge, onCommit: @escaping (String) -> Void) {
        current?.popover.close()
        let prompt = BookmarkNamePrompt()
        prompt.onCommit = onCommit
        prompt.popover.contentViewController = prompt
        prompt.popover.behavior = .transient
        prompt.popover.delegate = prompt
        current = prompt
        prompt.popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        prompt.view.window?.makeFirstResponder(prompt.field)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 44))
        field.frame = NSRect(x: 12, y: 11, width: 226, height: 22)
        field.placeholderString = "Bookmark name"
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        container.addSubview(field)
        view = container
    }

    @objc private func commit() {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let handler = onCommit
        onCommit = nil
        popover.close()
        handler?(name)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCommit = nil
        popover.close()
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}
