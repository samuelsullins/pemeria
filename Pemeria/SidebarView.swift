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
                guard let cell = rowView.view(atColumn: 0) as? SidebarCell,
                      let id = id(of: outline.item(atRow: row)) else { return }
                configure(cell, for: id)
            }
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
            SidebarRowView()
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

        /// "Icons ▸" with a checkable item per icon, then "Edit Icons…".
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
            submenu.addItem(withTitle: "Edit Icons…", action: #selector(editIcons), keyEquivalent: "").target = self
            let parent = menu.addItem(withTitle: "Icons", action: nil, keyEquivalent: "")
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

    private let icon = ClickableImageView()
    private let label = NSTextField(labelWithString: "")
    private let badges = IconFanView()

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
        addSubview(icon)
        addSubview(label)
        addSubview(badges)
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
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

    private var isWorkingFile = false

    func configure(with file: PemeriaFile, icons: [IconDefinition], isWorkingFile: Bool) {
        label.stringValue = file.title
        label.isEditable = false
        self.isWorkingFile = isWorkingFile
        // The Working File's fat arrow takes the leading spot (SPEC.md §8).
        if isWorkingFile {
            icon.image = NSImage(systemSymbolName: "arrowshape.right.fill", accessibilityDescription: "Working File")
            icon.toolTip = file.kind == .note ? "Working File (a note)" : "Working File"
        } else {
            icon.image = file.kind == .note ? NSImage(systemSymbolName: "note.text", accessibilityDescription: "Note") : nil
            icon.toolTip = nil
        }
        badges.icons = icons
        // Only the arrow is clickable; a note icon just selects the row like the rest of it.
        icon.onClick = isWorkingFile ? { [weak self] in
            guard let self else { return }
            self.onIconsClick?(self.badges)
        } : nil
        updateIconTint()
    }

    private func updateIconTint() {
        let selected = backgroundStyle == .emphasized
        badges.isOnSelection = selected
        icon.contentTintColor = isWorkingFile ? (selected ? .white : Theme.accent) : (selected ? .white : .secondaryLabelColor)
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
            toolTip = icons.isEmpty ? "Add Icons" : icons.map(\.name).joined(separator: ", ")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Add Icons"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var isOnSelection = false {
        didSet { if isOnSelection != oldValue { needsDisplay = true } }
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
            guard let image = IconSymbol.image(for: definition, pointSize: 11) else { continue }
            let halo = isOnSelection ? IconSymbol.image(for: definition, pointSize: 11, color: .white) : nil
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

/// Draws the selection in Pemeria's coral rather than the system accent.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let color = isEmphasized ? Theme.accent : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
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
