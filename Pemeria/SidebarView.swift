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
        // The system's own source-list selection: full width whatever the nesting, the usual
        // size, and it tells each row's cell when it's selected (SidebarCell.backgroundStyle).
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
        outline.onCommandDelete = { [weak coordinator] in coordinator?.trashWithoutAsking(coordinator?.model.selection ?? []) }

        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // A little room above the first file and below the last, so they don't touch the
        // Documents heading's divider or the footer. Set by hand: the list sits below the
        // heading now, so there's no title bar for the automatic insets to make room for.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        coordinator.outlineView = outline
        coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Reading these registers them for observation, so this runs again when they change.
        _ = (model.revision, model.appearanceRevision, model.selection, model.expanded, model.renameRequest)
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
        private var shownAppearance = -1
        private var iconPopover: NSPopover?
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
                shownAppearance = model.appearanceRevision
                items = items.filter { project.files[$0.key] != nil }
                outline.reloadData()
            } else if shownAppearance != model.appearanceRevision {
                shownAppearance = model.appearanceRevision
                refreshVisibleRows()
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

        /// Re-applies icons and the Working File arrow to the rows on screen, keeping their views.
        private func refreshVisibleRows() {
            guard let outline = outlineView else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let id = id(of: outline.item(atRow: row)) else { return }
                if let cell = rowView.view(atColumn: 0) as? SidebarCell { configure(cell, for: id) }
            }
        }

        private func configure(_ cell: SidebarCell, for id: FileID) {
            guard let file = project.files[id] else { return }
            if editingID != id {
                cell.configure(with: file, slots: project.iconSlots(of: id), isWorkingFile: project.manifest.workingFile == id)
            }
            cell.onSlotClick = { [weak self] slot, view, rect in self?.showIconPicker(for: id, slot: slot, from: view, rect: rect) }
        }

        /// Clicking one of a row's label slots opens the label list for that slot, as in the header.
        func showIconPicker(for id: FileID, slot: Int, from view: NSView, rect: NSRect) {
            iconPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            let host = NSHostingController(rootView: IconPickerList(model: model, fileID: id, slot: slot) { [weak self] in
                self?.iconPopover?.close()
            } onEditIcons: { [weak self] in
                self?.iconPopover?.close()
                self?.model.showIconEditor()
            })
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
            iconPopover = popover
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
            guard let id = id(of: item), project.files[id] != nil else { return nil }
            let cell = outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
            configure(cell, for: id)
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
            cell.isEditingName = true
            field.isEditable = true
            outline.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let id = editingID else { return }
            editingID = nil
            field.isEditable = false
            (field.superview as? SidebarCell)?.isEditingName = false
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

            // With the same shortcuts as the File menu, shown so they're easy to learn.
            menu.addItem(withTitle: "New Draft", action: #selector(newDraft), keyEquivalent: "n").target = self
            let newNoteItem = menu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "n")
            newNoteItem.keyEquivalentModifierMask = [.command, .option]
            newNoteItem.target = self
            guard !menuTargets.isEmpty else { return }

            menu.addItem(.separator())
            if menuTargets.count == 1 {
                menu.addItem(withTitle: "Rename", action: #selector(renameClicked), keyEquivalent: "").target = self
            }
            let kinds = Set(menuTargets.compactMap { project.files[$0]?.kind })
            // ⌃⌘N goes on the one it does: Turn into Note, unless they're all notes already.
            let shortcutTarget: FileKind = kinds == [.note] ? .draft : .note
            func addKindItem(_ title: String, _ action: Selector, _ kind: FileKind) {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: kind == shortcutTarget ? "n" : "")
                if kind == shortcutTarget { item.keyEquivalentModifierMask = [.command, .control] }
                item.target = self
            }
            if kinds.contains(.draft) { addKindItem("Turn into Note", #selector(makeNote), .note) }
            if kinds.contains(.note) { addKindItem("Turn into Draft", #selector(makeDraft), .draft) }
            menu.addItem(.separator())
            addIconsMenu(to: menu)
            if menuTargets.count == 1, let target = menuTargets.first {
                if project.manifest.workingFile == target {
                    menu.addItem(withTitle: "Clear Working File", action: #selector(clearWorkingFile), keyEquivalent: "").target = self
                } else {
                    let item = menu.addItem(withTitle: "Set as Working File", action: #selector(setWorkingFile), keyEquivalent: "j")
                    item.keyEquivalentModifierMask = [.command, .shift]
                    item.target = self
                }
            }
            menu.addItem(.separator())
            if menuTargets.count == 1 {
                menu.addItem(withTitle: "Browse Snapshots…", action: #selector(browseSnapshots), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: "Move to Trash…", action: #selector(trashClicked), keyEquivalent: "").target = self
        }

        @objc private func browseSnapshots() {
            model.commitEditors()
            model.historyFile = menuTargets.first
        }

        /// "Labels ▸" with a checkable item per label (icon), then "Edit Labels…".
        private func addIconsMenu(to menu: NSMenu) {
            let submenu = NSMenu()
            let targets = menuTargets.compactMap { project.files[$0] }
            for definition in project.manifest.icons {
                let item = submenu.addItem(withTitle: definition.name, action: #selector(toggleIcon(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = definition.id
                item.image = IconSymbol.image(for: definition, pointSize: 12)
                let having = targets.filter { project.icons(of: $0.id).contains(definition) }.count
                item.state = having == targets.count ? .on : having > 0 ? .mixed : .off
                // Adding needs an empty slot on at least one file.
                if having < targets.count {
                    item.isEnabled = targets.contains {
                        !project.icons(of: $0.id).contains(definition) && project.freeIconSlot(of: $0.id) != nil
                    }
                }
            }
            if !project.manifest.icons.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(withTitle: "Edit Labels…", action: #selector(editIcons), keyEquivalent: "").target = self
            let parent = menu.addItem(withTitle: "Labels", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            submenu.autoenablesItems = false
        }

        @objc private func toggleIcon(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            model.toggleIcon(id, on: menuTargets)
        }

        @objc private func editIcons() { model.showIconEditor() }
        @objc private func setWorkingFile() { model.setWorkingFile(menuTargets.first) }
        @objc private func clearWorkingFile() { model.setWorkingFile(nil) }

        @objc private func newDraft() { model.newFile(kind: .draft, after: menuTargets.last) }
        @objc private func newNote() { model.newFile(kind: .note, after: menuTargets.last) }
        @objc private func renameClicked() { menuTargets.first.map(beginRenaming) }
        @objc private func makeNote() { model.setKind(menuTargets, to: .note) }
        @objc private func makeDraft() { model.setKind(menuTargets, to: .draft) }
        @objc private func trashClicked() { confirmTrash(menuTargets) }

        /// ⌘⌫, as in Finder: straight to the trash, no question, since it can be restored from
        /// there. Still asks when files nested inside would go too, so they never vanish unseen.
        func trashWithoutAsking(_ ids: [FileID]) {
            let topmost = project.topmost(ids)
            guard !topmost.isEmpty else { return }
            if topmost.contains(where: { !project.descendants(of: $0).isEmpty }) {
                confirmTrash(topmost)
            } else {
                model.trash(topmost)
            }
        }

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
    /// Delete: move to the trash, after asking.
    var onDelete: (() -> Void)?
    /// ⌘⌫: move to the trash straight away.
    var onCommandDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys = [Character(UnicodeScalar(NSDeleteCharacter)!), Character(UnicodeScalar(NSDeleteFunctionKey)!)]
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let key = event.charactersIgnoringModifiers?.first, deleteKeys.contains(key), modifiers.isEmpty {
            onDelete?()
        } else if let key = event.charactersIgnoringModifiers?.first, deleteKeys.contains(key), modifiers == .command {
            onCommandDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    private let icon = ClickableImageView()
    private let label = NSTextField(labelWithString: "")
    private let slots = LabelSlotsView()
    /// The Working File's fat arrow, right before the name (SPEC.md §8). No room taken otherwise.
    private let workingArrow = NSImageView()
    private var workingArrowWidth: NSLayoutConstraint!
    private var workingArrowGap: NSLayoutConstraint!
    private var isWorkingFile = false

    /// Called with the slot, and the view and rect to point a popover at, when a label slot is clicked.
    var onSlotClick: ((Int, NSView, NSRect) -> Void)? {
        didSet { slots.onClick = onSlotClick }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        workingArrow.translatesAutoresizingMaskIntoConstraints = false
        workingArrow.imageScaling = .scaleNone
        workingArrow.setAccessibilityLabel("Working File")
        workingArrow.toolTip = "Working File (⌘J jumps here)"
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isSelectable = false
        label.cell?.usesSingleLineMode = true
        label.focusRingType = .none
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slots.translatesAutoresizingMaskIntoConstraints = false
        slots.setContentHuggingPriority(.required, for: .horizontal)
        slots.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(workingArrow)
        addSubview(icon)
        addSubview(label)
        addSubview(slots)
        imageView = icon
        textField = label

        workingArrowWidth = workingArrow.widthAnchor.constraint(equalToConstant: 0)
        workingArrowGap = icon.leadingAnchor.constraint(equalTo: workingArrow.trailingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            workingArrow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            workingArrow.centerYAnchor.constraint(equalTo: centerYAnchor),
            workingArrowWidth,
            workingArrowGap,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: slots.leadingAnchor, constant: -6),
            slots.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            slots.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// When the sidebar is narrower than this, every row's three slots fold into the width of
    /// one. (The sidebar can't go below 210, so this has to sit above that.)
    static let collapseBelowWidth: CGFloat = 250

    override func layout() {
        super.layout()
        // Decided from the whole sidebar, not this row (which narrows with nesting), so every
        // row folds at once and the slots always line up.
        let listWidth = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        slots.isCollapsed = listWidth < Self.collapseBelowWidth
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The row sets this as its selection changes: `.emphasized` while it's selected in the
    /// focused list (the accent fill). Everything on the row is white then, and only then.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    private var isOnAccent: Bool { backgroundStyle == .emphasized }

    /// Lets the labels and the Working File arrow take their own clicks; otherwise the outline
    /// view keeps the click for selecting the row (an image view never got it).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if event?.type == .leftMouseDown, responder === slots || (responder === icon && icon.onClick != nil) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    func configure(with file: PemeriaFile, slots: [IconDefinition?], isWorkingFile: Bool) {
        label.stringValue = file.title
        label.isEditable = false
        isEditingName = false
        self.isWorkingFile = isWorkingFile
        workingArrowWidth.constant = isWorkingFile ? 16 : 0
        workingArrowGap.constant = isWorkingFile ? 2 : 0
        workingArrow.isHidden = !isWorkingFile
        icon.image = file.kind == .note ? NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note") : nil
        self.slots.slots = slots
        updateTint()
    }

    /// While renaming, the name sits in a plain text box in the usual text colours, so it reads
    /// in light and dark mode whatever the row behind it.
    var isEditingName = false {
        didSet {
            guard isEditingName != oldValue else { return }
            label.drawsBackground = isEditingName
            label.backgroundColor = .textBackgroundColor
            updateTint()
        }
    }

    private func updateTint() {
        // White only on the accent fill of a selected row; the system's usual text colour
        // otherwise (including a selected row in a list that isn't focused, which is gray).
        let white = isOnAccent && !isEditingName
        slots.isOnSelection = isOnAccent
        label.textColor = white ? .white : .labelColor
        icon.contentTintColor = isOnAccent ? .white : .secondaryLabelColor
        if isWorkingFile {
            // Accent coloured on a plain row; white on the accent.
            let color: NSColor = isOnAccent ? .white : Theme.accent
            workingArrow.image = NSImage(systemSymbolName: "arrowshape.right.fill", accessibilityDescription: "Working File")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [color])))
        }
    }
}

/// A file's three label slots at the trailing end of its sidebar row (SPEC.md §4): a square
/// for each, its label's colour with the symbol in white, or gray while empty. Click a slot to
/// choose its label. When the row is narrow, the three fold into the width of one, as three
/// stripes of plain colour.
final class LabelSlotsView: NSView {
    var slots: [IconDefinition?] = Array(repeating: nil, count: Project.maxIconsPerFile) {
        didSet {
            guard slots != oldValue else { return }
            needsDisplay = true
            let names = slots.compactMap { $0?.name }
            toolTip = names.isEmpty ? "Add Labels" : names.joined(separator: ", ")
        }
    }

    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var isOnSelection = false {
        didSet { if isOnSelection != oldValue { needsDisplay = true } }
    }

    /// The clicked slot, this view, and the slot's rect.
    var onClick: ((Int, NSView, NSRect) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Add Labels"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    static let side: CGFloat = 18
    static let gap: CGFloat = 2

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(Project.maxIconsPerFile)
        let width = isCollapsed ? Self.side : count * Self.side + (count - 1) * Self.gap
        return NSSize(width: width, height: Self.side)
    }

    override var isFlipped: Bool { true }

    /// Each slot's rect: squares side by side, or thin stripes of one square when collapsed.
    private func rect(ofSlot slot: Int) -> NSRect {
        let top = bounds.midY - Self.side / 2
        if isCollapsed {
            let width = Self.side / CGFloat(slots.count)
            return NSRect(x: CGFloat(slot) * width, y: top, width: width, height: Self.side)
        }
        return NSRect(x: CGFloat(slot) * (Self.side + Self.gap), y: top, width: Self.side, height: Self.side)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let slot = slots.indices.first { rect(ofSlot: $0).insetBy(dx: -Self.gap / 2, dy: -4).contains(point) }
            ?? (point.x < bounds.midX ? 0 : slots.count - 1)
        onClick(slot, self, rect(ofSlot: slot))
    }

    private var emptyColor: NSColor {
        isOnSelection ? NSColor.white.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(0.1)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCollapsed {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: 0, y: bounds.midY - Self.side / 2, width: Self.side, height: Self.side),
                         xRadius: 4, yRadius: 4).addClip()
            for (index, definition) in slots.enumerated() {
                (definition.flatMap { NSColor(hex: $0.color) } ?? emptyColor).setFill()
                // A hair of overlap so no seam shows between stripes.
                rect(ofSlot: index).insetBy(dx: -0.25, dy: 0).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        for (index, definition) in slots.enumerated() {
            let square = rect(ofSlot: index)
            (definition.flatMap { NSColor(hex: $0.color) } ?? emptyColor).setFill()
            NSBezierPath(roundedRect: square, xRadius: 4, yRadius: 4).fill()
            guard let definition, let image = IconSymbol.image(for: definition, pointSize: 10, color: .white) else { continue }
            image.draw(in: CGRect(x: square.midX - image.size.width / 2, y: square.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }
}

/// An image that handles clicks itself when `onClick` is set, instead of selecting the row.
final class ClickableImageView: NSImageView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

/// An icon's symbol as an image in its colour (or another).
enum IconSymbol {
    static func image(for definition: IconDefinition, pointSize: CGFloat, color: NSColor? = nil) -> NSImage? {
        let color = color ?? NSColor(hex: definition.color) ?? .secondaryLabelColor
        return NSImage(systemSymbolName: definition.symbol, accessibilityDescription: definition.name)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold).applying(.init(paletteColors: [color])))
    }
}

extension NSColor {
    /// "#RRGGBB" (or without the #).
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }
}
