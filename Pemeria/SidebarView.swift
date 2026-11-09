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
        // Pemeria draws the selection itself (SidebarRowView), so a selected row can keep a
        // stripe of its label colours inside the accent fill.
        outline.selectionHighlightStyle = .none
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
                (rowView as? SidebarRowView)?.fillColors = fillColors(for: id)
                if let cell = rowView.view(atColumn: 0) as? SidebarCell { configure(cell, for: id) }
            }
        }

        /// A file's icon colours, which fill its row (SPEC.md §4).
        private func fillColors(for id: FileID) -> [NSColor] {
            project.icons(of: id).map { NSColor(hex: $0.color) ?? .secondaryLabelColor }
        }

        private func configure(_ cell: SidebarCell, for id: FileID) {
            guard let file = project.files[id] else { return }
            if editingID != id {
                cell.configure(with: file, icons: project.icons(of: id), isWorkingFile: project.manifest.workingFile == id)
            }
            cell.onIconsClick = { [weak self] view in self?.showIconPicker(for: id, from: view) }
        }

        /// Clicking a row's icons (or Working File arrow) opens the same icon list as the header.
        func showIconPicker(for id: FileID, from view: NSView) {
            iconPopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            let host = NSHostingController(rootView: IconPickerList(model: model, fileID: id) { [weak self] in
                self?.iconPopover?.close()
                self?.model.showIconEditor()
            })
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
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

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let rowView = SidebarRowView()
            if let id = id(of: item) {
                rowView.fillColors = fillColors(for: id)
            }
            return rowView
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
                menu.addItem(withTitle: "Turn into Note", action: #selector(makeNote), keyEquivalent: "").target = self
            }
            if kinds.contains(.note) {
                menu.addItem(withTitle: "Turn into Draft", action: #selector(makeDraft), keyEquivalent: "").target = self
            }
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
                let having = targets.filter { $0.icons.contains(definition.id) }.count
                item.state = having == targets.count ? .on : having > 0 ? .mixed : .off
                // Adding needs room on at least one file.
                if having < targets.count {
                    item.isEnabled = targets.contains {
                        !$0.icons.contains(definition.id) && project.icons(of: $0.id).count < Project.maxIconsPerFile
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

    /// Extra room on the left of every row, so the fills don't run into the window edge.
    static let leadingRoom: CGFloat = 14

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x += Self.leadingRoom
        frame.size.width = max(0, frame.width - Self.leadingRoom)
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += Self.leadingRoom
        return frame
    }

    /// Plain chevrons for folding, tinted by the row (white on a coloured row), instead of the
    /// system's disclosure triangle, which didn't draw well on the coloured fills.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier, let button = view as? NSButton {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            button.setButtonType(.toggle)
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")?
                .withSymbolConfiguration(configuration)
            button.alternateImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Collapse")?
                .withSymbolConfiguration(configuration)
            if button.contentTintColor == nil { button.contentTintColor = .secondaryLabelColor }
        }
        return view
    }

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
    private let badges = IconFanView()
    /// The Working File's fat arrow, right before the name (SPEC.md §8). No room taken otherwise.
    private let workingArrow = NSImageView()
    private var workingArrowWidth: NSLayoutConstraint!
    private var workingArrowGap: NSLayoutConstraint!
    private var isWorkingFile = false

    /// Called with the clicked view when the icons or the Working File arrow are clicked.
    var onIconsClick: ((NSView) -> Void)? {
        didSet {
            badges.onClick = onIconsClick.map { handler in { [unowned badges] in handler(badges) } }
        }
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
        badges.translatesAutoresizingMaskIntoConstraints = false
        badges.setContentHuggingPriority(.required, for: .horizontal)
        badges.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(workingArrow)
        addSubview(icon)
        addSubview(label)
        addSubview(badges)
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
            badges.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            badges.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            badges.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateIconTint() }
    }

    /// Lets the Working File arrow and the icons take their own clicks; otherwise the outline
    /// view keeps the click for selecting the row (an image view never got it).
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if event?.type == .leftMouseDown, responder === badges || (responder === icon && icon.onClick != nil) {
            return true
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    /// The row is filled with the file's icon colours, so everything on it is white.
    private var isOnColor = false

    func configure(with file: PemeriaFile, icons: [IconDefinition], isWorkingFile: Bool) {
        label.stringValue = file.title
        label.isEditable = false
        self.isWorkingFile = isWorkingFile
        workingArrowWidth.constant = isWorkingFile ? 16 : 0
        workingArrowGap.constant = isWorkingFile ? 2 : 0
        workingArrow.isHidden = !isWorkingFile
        icon.image = file.kind == .note ? NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note") : nil
        badges.icons = icons
        isOnColor = !icons.isEmpty
        updateIconTint()
    }

    /// Set by the row: selected rows are filled with the accent colour.
    var isRowSelected = false {
        didSet { if isRowSelected != oldValue { updateIconTint() } }
    }

    private func updateIconTint() {
        // On the accent fill or a label fill, everything is white.
        let white = isRowSelected || isOnColor
        badges.isOnSelection = isRowSelected
        badges.isOnColor = white
        label.textColor = white ? .white : .labelColor
        icon.contentTintColor = white ? .white : .secondaryLabelColor
        if isWorkingFile {
            // Accent coloured on a plain row; white on the accent or a label colour.
            let color: NSColor = white ? .white : Theme.accent
            workingArrow.image = NSImage(systemSymbolName: "arrowshape.right.fill", accessibilityDescription: "Working File")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .bold).applying(.init(paletteColors: [color])))
        }
    }
}

/// Up to three file icons, overlapping and fanned like a hand of cards (SPEC.md §4).
/// Each is its symbol in its colour; on a selected row each gets a thin white halo.
/// With no icons it shows a faint tag, as the header does, so there's something to click.
final class IconFanView: NSView {
    var icons: [IconDefinition] = [] {
        didSet {
            guard icons != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            toolTip = icons.isEmpty ? "Add Labels" : icons.map(\.name).joined(separator: ", ")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Add Labels"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var isOnSelection = false {
        didSet { if isOnSelection != oldValue { needsDisplay = true } }
    }

    /// On a row filled with the icons' colours: each icon is drawn in white, with no halo.
    var isOnColor = false {
        didSet { if isOnColor != oldValue { needsDisplay = true } }
    }

    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }

    static let size: CGFloat = 14
    static let step: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        guard !icons.isEmpty else { return NSSize(width: Self.size + 4, height: Self.size + 4) }
        return NSSize(width: Self.size + CGFloat(icons.count - 1) * Self.step + 4, height: Self.size + 4)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if icons.isEmpty {
            let color: NSColor = isOnSelection ? .white.withAlphaComponent(0.55) : .tertiaryLabelColor
            guard let tag = NSImage(systemSymbolName: "tag", accessibilityDescription: "Add Icons")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [color])))
            else { return }
            tag.draw(in: CGRect(x: bounds.midX - tag.size.width / 2, y: bounds.midY - tag.size.height / 2,
                                width: tag.size.width, height: tag.size.height))
            return
        }
        let angles: [CGFloat] = switch icons.count {
        case 1: [0]
        case 2: [-7, 7]
        default: [-10, 0, 10]
        }
        for (index, definition) in icons.enumerated() {
            guard let image = IconSymbol.image(for: definition, pointSize: 11, color: isOnColor ? .white : nil) else { continue }
            let halo = isOnSelection && !isOnColor ? IconSymbol.image(for: definition, pointSize: 11, color: .white) : nil
            let center = CGPoint(x: 2 + Self.size / 2 + CGFloat(index) * Self.step, y: bounds.midY)
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angles[index] * .pi / 180)
            let rect = CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height)
            if let halo {
                for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7)] {
                    halo.draw(in: rect.offsetBy(dx: dx, dy: dy))
                }
            }
            image.draw(in: rect)
            context.restoreGState()
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

/// A file with icons has its row filled with their colours, side by side in equal vertical bands
/// (SPEC.md §4). A selected row is filled with the accent colour instead, like any Mac list, and
/// keeps its label colours as a stripe down its left edge. Selected rows next to each other join.
final class SidebarRowView: NSTableRowView {
    var fillColors: [NSColor] = [] {
        didSet {
            guard fillColors != oldValue else { return }
            updateDisclosureTint()
            needsDisplay = true
        }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            updateDisclosureTint()
            updateCellSelection()
            needsDisplay = true
        }
    }

    private func updateCellSelection() {
        for column in 0..<numberOfColumns {
            (view(atColumn: column) as? SidebarCell)?.isRowSelected = isSelected
        }
    }

    override var isPreviousRowSelected: Bool {
        didSet { if isPreviousRowSelected != oldValue { needsDisplay = true } }
    }

    override var isNextRowSelected: Bool {
        didSet { if isNextRowSelected != oldValue { needsDisplay = true } }
    }


    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateDisclosureTint()
        updateCellSelection()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    private var disclosureButton: NSButton? {
        subviews.first { $0.identifier == NSOutlineView.disclosureButtonIdentifier && !$0.isHidden } as? NSButton
    }

    /// The fold chevron matches the text: white on a coloured or selected row.
    private func updateDisclosureTint() {
        disclosureButton?.contentTintColor = fillColors.isEmpty && !isSelected ? .secondaryLabelColor : .white
    }

    /// Width of the fold chevron's slot before each row's content. Rows without children keep
    /// the slot too, so every row at one level starts its fill in the same place.
    private static let chevronSlot: CGFloat = 13

    /// The fill sits around the row's content (and its fold chevron's slot), so it steps in with
    /// each level of nesting.
    private var pillRect: NSRect {
        let cell = view(atColumn: 0) as? NSView
        let start = (cell?.frame.minX ?? bounds.minX + 39) - Self.chevronSlot - 6
        let end = min(bounds.maxX - 8, (cell?.frame.maxX ?? bounds.maxX) + 2)
        return NSRect(x: start, y: bounds.minY + 1, width: max(0, end - start), height: bounds.height - 2)
    }

    /// Width of the label stripe down a selected row's left edge.
    private static let stripeWidth: CGFloat = 6

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        updateDisclosureTint()
        let rect = pillRect
        if isSelected {
            drawSelectedFill(in: rect)
        } else if !fillColors.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            let width = rect.width / CGFloat(fillColors.count)
            for (index, color) in fillColors.enumerated() {
                color.setFill()
                // A hair of overlap so no seam shows between bands.
                NSRect(x: rect.minX + CGFloat(index) * width, y: rect.minY, width: width + 0.5, height: rect.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Drawn here rather than in `drawSelection`, which a highlight style of `.none` never calls.
    /// The accent fill runs on into a selected neighbour, so a run of selected rows is one block;
    /// the label colours sit in a stripe down the left edge, stacked top to bottom.
    private func drawSelectedFill(in pill: NSRect) {
        // Run on past the row's edge towards a selected neighbour; the row clips it square there,
        // so it meets the neighbour's fill seamlessly.
        let overhang: CGFloat = 8
        var rect = pill
        if isPreviousRowSelected {
            rect.size.height += rect.minY - bounds.minY + overhang
            rect.origin.y = bounds.minY - overhang
        }
        if isNextRowSelected { rect.size.height = bounds.maxY + overhang - rect.minY }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        Theme.accent.setFill()
        rect.fill()
        if !fillColors.isEmpty {
            // The stripe is this row's own, so it keeps to the row.
            let top = max(rect.minY, bounds.minY)
            let bottom = min(rect.maxY, bounds.maxY)
            let height = (bottom - top) / CGFloat(fillColors.count)
            for (index, color) in fillColors.enumerated() {
                color.setFill()
                NSRect(x: rect.minX, y: top + CGFloat(index) * height, width: Self.stripeWidth, height: height + 0.5).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
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
