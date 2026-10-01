import AppKit

/// The small popup for naming a bookmark: ⌘D opens it at the cursor to name a new one, and
/// clicking a margin icon opens it with the name ready to edit and a Delete button.
/// Return saves, Esc cancels.
final class BookmarkNamePrompt: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    /// Keeps the open prompt alive until its popover closes.
    private static var current: BookmarkNamePrompt?

    private let field = NSTextField()
    private let popover = NSPopover()
    private var onCommit: ((String) -> Void)?
    private var onDelete: (() -> Void)?

    static func show(
        relativeTo rect: NSRect,
        of view: NSView,
        preferredEdge: NSRectEdge,
        initialName: String = "",
        onDelete: (() -> Void)? = nil,
        onCommit: @escaping (String) -> Void
    ) {
        current?.popover.close()
        let prompt = BookmarkNamePrompt()
        prompt.onCommit = onCommit
        prompt.onDelete = onDelete
        prompt.loadViewIfNeeded()
        prompt.field.stringValue = initialName
        prompt.popover.contentViewController = prompt
        prompt.popover.behavior = .transient
        prompt.popover.delegate = prompt
        current = prompt
        prompt.popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        prompt.view.window?.makeFirstResponder(prompt.field)
        prompt.field.currentEditor()?.selectAll(nil)
    }

    override func loadView() {
        let container = NSView()
        field.placeholderString = "Bookmark name"
        field.delegate = self
        field.target = self
        field.action = #selector(commit)
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        var constraints = [
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -11),
            field.widthAnchor.constraint(equalToConstant: 280),
        ]
        if onDelete != nil {
            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteBookmark))
            delete.bezelStyle = .push
            delete.hasDestructiveAction = true
            delete.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(delete)
            constraints += [
                delete.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
                delete.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                delete.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            ]
        } else {
            constraints.append(field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12))
        }
        NSLayoutConstraint.activate(constraints)
        view = container
    }

    @objc private func commit() {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let handler = onCommit
        onCommit = nil
        onDelete = nil
        popover.close()
        handler?(name)
    }

    @objc private func deleteBookmark() {
        let handler = onDelete
        onCommit = nil
        onDelete = nil
        popover.close()
        handler?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onCommit = nil
        onDelete = nil
        popover.close()
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}
