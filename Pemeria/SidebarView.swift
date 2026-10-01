import AppKit
import PemeriaCore
import SwiftUI

extension NSPasteboard.PasteboardType {
    static let pemeriaFileID = NSPasteboard.PasteboardType("com.samuelsullins.pemeria.file-id")
}

/// The file tree. Built on NSOutlineView for proper drag-to-reorder/nest, multi-select,
/// folding and inline renaming. See SPEC.md §4.
struct SidebarView: NSViewRepresentable {
    let model: ProjectModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = SidebarOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.allowsMultipleSelection = true
        outline.indentationPerLevel = 14
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        outline.registerForDraggedTypes([.pemeriaFileID])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.onDelete = { [weak coordinator] in coordinator?.confirmTrash(coordinator?.model.selection ?? []) }

        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        coordinator.outlineView = outline
        coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Reading these registers them for observation, so this runs again when they change.
        _ = (model.revision, model.selection, model.expanded, model.renameRequest)
        context.coordinator.model = model
        context.coordinator.sync()
    }

    // MARK: -

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var model: ProjectModel
        weak var outlineView: NSOutlineView?

        /// NSOutlineView tracks items by object identity, so each file keeps one item object.
        private var items: [FileID: SidebarItem] = [:]
        private var shownRevision = -1
        /// True while pushing model state into the view, so view callbacks don't echo it back.
        private var isSyncing = false
        private var editingID: FileID?
        private var draggedIDs: [FileID] = []
        private var menuTargets: [FileID] = []

        init(model: ProjectModel) {
            self.model = model
        }

        private var project: Project { model.project }

        private func item(for id: FileID) -> SidebarItem {
            if let item = items[id] { return item }
            let item = SidebarItem(id: id)
            items[id] = item
            return item
        }

        private func id(of item: Any?) -> FileID? {
            (item as? SidebarItem)?.id
        }

        // MARK: Model → view

        func sync() {
            guard let outline = outlineView else { return }
            isSyncing = true
            defer { isSyncing = false }

            if shownRevision != model.revision, editingID == nil {
                shownRevision = model.revision
                items = items.filter { project.files[$0.key] != nil }
                outline.reloadData()
            }

            for id in project.tree.bookOrder where !project.tree.children(of: id).isEmpty {
                let item = item(for: id)
                if model.expanded.contains(id) {
                    if !outline.isItemExpanded(item) { outline.expandItem(item) }
                } else if outline.isItemExpanded(item) {
                    outline.collapseItem(item)
                }
            }

            let rows = IndexSet(model.selection.compactMap { items[$0].map(outline.row(forItem:)) }.filter { $0 >= 0 })
            if outline.selectedRowIndexes != rows {
                outline.selectRowIndexes(rows, byExtendingSelection: false)
                if let first = rows.first { outline.scrollRowToVisible(first) }
            }

            if let request = model.renameRequest {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.model.renameRequest == request else { return }
                    self.model.renameRequest = nil
                    self.beginRenaming(request)
                }
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            project.children(of: id(of: item)).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            self.item(for: project.children(of: id(of: item))[index])
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let id = id(of: item) else { return false }
            return !project.tree.children(of: id).isEmpty
        }

        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let id = id(of: item), let file = project.files[id] else { return nil }
            let cell = outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
            cell.configure(with: file)
            cell.textField?.delegate = self
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline = outlineView else { return }
            model.selection = outline.selectedRowIndexes.compactMap { id(of: outline.item(atRow: $0)) }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !isSyncing, let id = id(of: notification.userInfo?["NSObject"]) else { return }
            model.expanded.insert(id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !isSyncing, let id = id(of: notification.userInfo?["NSObject"]) else { return }
            model.expanded.remove(id)
        }

        // MARK: Renaming

        @objc func doubleClicked() {
            guard let outline = outlineView, outline.clickedRow >= 0, let id = id(of: outline.item(atRow: outline.clickedRow)) else { return }
            beginRenaming(id)
        }

        func beginRenaming(_ id: FileID) {
            guard let outline = outlineView, let item = items[id] else { return }
            let row = outline.row(forItem: item)
            guard row >= 0 else { return }
            outline.scrollRowToVisible(row)
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
                  let field = cell.textField else { return }
            editingID = id
            field.isEditable = true
            outline.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let id = editingID else { return }
            editingID = nil
            field.isEditable = false
            model.rename(id, to: field.stringValue)
            field.stringValue = project.files[id]?.title ?? field.stringValue
            outlineView?.window?.makeFirstResponder(outlineView)
            sync()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)), let id = editingID else { return false }
            // Esc: put the old name back, then end editing (which then sees no change).
            textView.string = project.files[id]?.title ?? textView.string
            outlineView?.window?.makeFirstResponder(outlineView)
            return true
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let id = id(of: item) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(id.rawValue, forType: .pemeriaFileID)
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
            draggedIDs = draggedItems.compactMap(id(of:))
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            draggedIDs = []
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard info.draggingSource as? NSOutlineView === outlineView, !draggedIDs.isEmpty else { return [] }
            return project.canMove(project.topmost(draggedIDs), into: id(of: item)) ? .move : []
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let parent = id(of: item)
            // Dropping onto a row (rather than between rows) nests at the end of its children.
            let position = index == NSOutlineViewDropOnItemIndex ? project.children(of: parent).count : index
            return model.move(draggedIDs, into: parent, at: position)
        }

        // MARK: Context menu

        /// Right-clicking a selected row acts on the whole selection; any other row acts on just that row.
        private func clickedTargets() -> [FileID] {
            guard let outline = outlineView, outline.clickedRow >= 0,
                  let clicked = id(of: outline.item(atRow: outline.clickedRow)) else { return [] }
            return model.selection.contains(clicked) ? model.selection : [clicked]
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuTargets = clickedTargets()

            menu.addItem(withTitle: "New Draft", action: #selector(newDraft), keyEquivalent: "").target = self
            menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "").target = self
            guard !menuTargets.isEmpty else { return }

            menu.addItem(.separator())
            if menuTargets.count == 1 {
                menu.addItem(withTitle: "Rename", action: #selector(renameClicked), keyEquivalent: "").target = self
            }
            let kinds = Set(menuTargets.compactMap { project.files[$0]?.kind })
            if kinds.contains(.draft) {
                menu.addItem(withTitle: "Make Note", action: #selector(makeNote), keyEquivalent: "").target = self
            }
            if kinds.contains(.note) {
                menu.addItem(withTitle: "Make Draft", action: #selector(makeDraft), keyEquivalent: "").target = self
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash…", action: #selector(trashClicked), keyEquivalent: "").target = self
        }

        @objc private func newDraft() { model.newFile(kind: .draft, after: menuTargets.last) }
        @objc private func newNote() { model.newFile(kind: .note, after: menuTargets.last) }
        @objc private func renameClicked() { menuTargets.first.map(beginRenaming) }
        @objc private func makeNote() { model.setKind(menuTargets, to: .note) }
        @objc private func makeDraft() { model.setKind(menuTargets, to: .draft) }
        @objc private func trashClicked() { confirmTrash(menuTargets) }

        func confirmTrash(_ ids: [FileID]) {
            let topmost = project.topmost(ids)
            guard !topmost.isEmpty, let window = outlineView?.window else { return }
            let nested = topmost.flatMap(project.descendants(of:)).count

            let alert = NSAlert()
            if topmost.count == 1, let title = project.files[topmost[0]]?.title {
                alert.messageText = "Move “\(title)” to the Trash?"
            } else {
                alert.messageText = "Move \(topmost.count) files to the Trash?"
            }
            var details: [String] = []
            if nested > 0 {
                details.append(nested == 1 ? "1 nested file goes with it." : "\(nested) nested files go with it.")
            }
            details.append("Trashed files are kept in the project’s trash folder, not permanently deleted.")
            alert.informativeText = details.joined(separator: " ")
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.model.trash(topmost) }
            }
        }
    }
}

final class SidebarItem: NSObject {
    let id: FileID

    init(id: FileID) {
        self.id = id
    }
}

final class SidebarOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys = [Character(UnicodeScalar(NSDeleteCharacter)!), Character(UnicodeScalar(NSDeleteFunctionKey)!)]
        if let key = event.charactersIgnoringModifiers?.first, deleteKeys.contains(key),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.cell?.usesSingleLineMode = true
        label.focusRingType = .none
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func configure(with file: PemeriaFile) {
        label.stringValue = file.title
        label.isEditable = false
        switch file.kind {
        case .note:
            icon.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note")
        case .draft:
            icon.image = nil
        }
    }
}
