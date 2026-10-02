import AppKit
import PemeriaCore
import SwiftUI

/// The right-hand side of the window: one editor pane, or two side by side (SPEC.md §12).
struct EditorArea: View {
    let model: ProjectModel

    var body: some View {
        if model.isSplit {
            PaneSplit {
                EditorPane(model: model, pane: 0)
            } trailing: {
                EditorPane(model: model, pane: 1)
            }
        } else {
            EditorPane(model: model, pane: 0)
        }
    }
}

/// One editor pane: the file name(s), the editor, (when pinned) the outline pane, and the word count.
struct EditorPane: View {
    let model: ProjectModel
    let pane: Int

    var body: some View {
        let selected = Set(model.selection(forPane: pane))
        let files = model.project.tree.bookOrder.filter(selected.contains).compactMap { model.project.files[$0] }
        // While split, the active pane wears a coral bar along its top.
        let isActive = model.isSplit && model.activePane == pane
        Group {
            if files.isEmpty {
                ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Select a file in the sidebar."))
                    .contentShape(Rectangle())
                    .onTapGesture { model.activate(pane: pane) }
                    .overlay(alignment: .topTrailing) {
                        SplitButton(model: model, pane: pane)
                            .padding(.trailing, 12)
                            .padding(.top, 9)
                    }
            } else {
                VStack(spacing: 0) {
                    EditorHeader(model: model, pane: pane, files: files)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { model.activate(pane: pane) })
                    Divider()
                    if model.isReading(pane: pane) {
                        EditorView(model: model, mode: .reading, pane: pane)
                    } else if model.isOutlineView(pane: pane) {
                        if files.contains(where: { $0.kind == .draft }) {
                            EditorView(model: model, mode: .outlineView, pane: pane)
                        } else {
                            Text("Notes don’t have outlines.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else if model.outlinePinned, files.contains(where: { $0.kind == .draft }) {
                        OutlineSplit {
                            EditorView(model: model, mode: .bodies, pane: pane)
                        } bottom: {
                            PinnedOutlinePane(model: model, pane: pane)
                        }
                    } else if model.outlinePinned {
                        // Notes have no outline, so there's no pane to pin.
                        EditorView(model: model, mode: .bodies, pane: pane)
                    } else {
                        EditorView(model: model, mode: .full, pane: pane)
                    }
                    Divider()
                    WordCountBar(model: model, pane: pane, files: files.map(\.id))
                }
            }
        }
        .overlay(alignment: .top) {
            if isActive {
                Theme.accentColor.frame(height: 2)
            }
        }
    }
}

/// The file name above the editor: Read mode and one-click copy on the left; Draft | Outline and
/// split view on the right.
/// With one file selected the name is editable in place, and its icons sit beside it (SPEC.md §12).
private struct EditorHeader: View {
    let model: ProjectModel
    let pane: Int
    let files: [PemeriaFile]

    var body: some View {
        ZStack {
            if files.count == 1, let file = files.first {
                HeaderTitleWithIcons(model: model, fileID: file.id) {
                    RenameField(name: file.title) { model.rename(file.id, to: $0) }
                        .id(file.id)
                }
            } else {
                Text(files.map(\.title).joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, 72)
        .padding(.trailing, 150)
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            let reading = model.isReading(pane: pane)
            HStack(spacing: 10) {
                Button {
                    model.toggleReadMode(pane: pane)
                } label: {
                    // On: full strength rather than coral, so the header stays quiet.
                    Image(systemName: "eye.fill")
                        .foregroundStyle(reading ? Color.primary : Color.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(reading ? "Exit Read Mode (⇧⌘R)" : "Read Mode (⇧⌘R): hide comments, outlines and bookmarks")
                CopyButton(help: files.count == 1 ? "Copy Draft Text" : "Copy Draft Text of All \(files.count) Files") {
                    model.copyDraftText(of: files.map(\.id))
                }
            }
            .padding(.leading, 12)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 10) {
                DraftOutlineToggle(model: model, pane: pane)
                SplitButton(model: model, pane: pane)
            }
            .padding(.trailing, 12)
        }
    }
}

/// Click and type to rename. Return or clicking away saves; Esc puts the old name back.
private struct RenameField: View {
    let name: String
    var alignment: TextAlignment = .center
    let onRename: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        // Sized to the name (the hidden text), so the icons can sit right beside it.
        Text(text.isEmpty ? "Name" : text)
            .font(.headline)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 3)
            .hidden()
            .overlay {
                TextField("Name", text: $text)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .multilineTextAlignment(alignment)
                    .focused($focused)
            }
            .onAppear { text = name }
            .onChange(of: name) { _, name in
                if !focused { text = name }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { focused = false }
            // Clicking another file mid-rename removes this field before it loses focus.
            .onDisappear { commit() }
            .onExitCommand {
                text = name
                focused = false
            }
            .help("Click to rename")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == name {
            text = name
        } else {
            onRename(trimmed)
        }
    }
}

/// Draft | Outline, at the right of the header: the highlighted one is what the pane shows.
private struct DraftOutlineToggle: View {
    let model: ProjectModel
    let pane: Int

    var body: some View {
        let outline = model.isOutlineView(pane: pane)
        HStack(spacing: 0) {
            segment("Draft", selected: !outline) { model.setOutlineView(false, pane: pane) }
            segment("Outline", selected: outline) { model.setOutlineView(true, pane: pane) }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize()
        .help("Draft or Outline view (⇧⌘O)")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.accentColor : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Splits the editor in two; while split, an × that closes this pane.
private struct SplitButton: View {
    let model: ProjectModel
    let pane: Int

    var body: some View {
        Button {
            if model.isSplit { model.closePane(pane) } else { model.toggleSplit() }
        } label: {
            Image(systemName: model.isSplit ? "xmark" : "rectangle.split.2x1.fill")
                .foregroundStyle(Color.secondary)
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(model.isSplit ? "Close This Pane" : "Split View (⌘\\)")
    }
}

/// A copy icon that briefly turns into a checkmark.
struct CopyButton: View {
    let help: String
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            // Color.secondary, not .secondary: the latter is a shade of the button's coral tint.
            Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                .foregroundStyle(Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// The word count of the selected drafts' text; click for the full breakdown (SPEC.md §10).
private struct WordCountBar: View {
    let model: ProjectModel
    let pane: Int
    let files: [FileID]
    @State private var showingDetails = false

    var body: some View {
        let counts = model.wordCounts(selected: files)
        let onlyNotes = !files.contains { model.project.files[$0]?.kind == .draft }
        let label = if let selected = model.selectedTextWords, !model.isSplit || model.selectedTextPane == pane {
            "\(Self.words(selected)) selected"
        } else if model.isOutlineView(pane: pane), !onlyNotes {
            "\(Self.words(counts.currentOutline)) in outline"
        } else {
            Self.words(counts.currentDraft)
        }
        Button {
            showingDetails.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Word count. Click for details.")
        .popover(isPresented: $showingDetails, arrowEdge: .top) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                row(onlyNotes ? "Current Note" : "Current Draft", counts.currentDraft)
                if !onlyNotes { row("Current Outline", counts.currentOutline) }
                Divider()
                row("Total Draft", counts.totalDraft)
                row("Total Outline", counts.totalOutline)
                Divider()
                row("Entire Project", counts.entireProject)
                GridRow {
                    Text("Drafts, outlines and notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
            .padding(14)
        }
    }

    private func row(_ title: String, _ count: Int) -> some View {
        GridRow {
            Text(title)
            Text(count, format: .number)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(count.formatted()) words"
    }
}

/// The grab strip over a split's divider. AppKit rather than a SwiftUI gesture: the text views
/// beside it are AppKit views, and they win clicks over any SwiftUI gesture under them, which
/// left only the header strip draggable.
private struct SplitHandle: NSViewRepresentable {
    static let thickness: CGFloat = 9

    /// `.horizontal`: a divider between left and right panes, dragged sideways.
    let axis: Axis
    let onBegin: () -> Void
    /// Distance dragged since the mouse went down: rightwards, or downwards.
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.handle = self
    }

    final class HandleView: NSView {
        var handle: SplitHandle? {
            didSet { if handle?.axis != oldValue?.axis { window?.invalidateCursorRects(for: self) } }
        }
        private var start: NSPoint?

        private var cursor: NSCursor { handle?.axis == .vertical ? .resizeUpDown : .resizeLeftRight }

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick = handle?.onDoubleClick {
                start = nil
                onDoubleClick()
                return
            }
            start = event.locationInWindow
            handle?.onBegin()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let handle else { return }
            cursor.set()
            let point = event.locationInWindow
            // Window coordinates run upwards.
            handle.onDrag(handle.axis == .horizontal ? point.x - start.x : start.y - point.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            handle?.onEnd()
        }
    }
}

/// Editor above, outline pane below, with a draggable divider. (SwiftUI's VSplitView crashed
/// here: its split view and the text views fought over layout.)
private struct OutlineSplit<Top: View, Bottom: View>: View {
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    @AppStorage("outlinePaneHeight") private var paneHeight = 220.0
    @State private var dragStartHeight: Double?

    private let minTop = 160.0
    private let minPane = 90.0

    var body: some View {
        GeometryReader { geometry in
            let maxPane = max(minPane, geometry.size.height - minTop)
            let height = min(max(paneHeight, minPane), maxPane)
            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                bottom
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
            .overlay(alignment: .topLeading) {
                SplitHandle(axis: .vertical) {
                    dragStartHeight = height
                } onDrag: { distance in
                    let start = dragStartHeight ?? height
                    paneHeight = min(max(start - distance, minPane), maxPane)
                } onEnd: {
                    dragStartHeight = nil
                }
                .frame(width: geometry.size.width, height: SplitHandle.thickness)
                .offset(y: geometry.size.height - height - 0.5 - SplitHandle.thickness / 2)
            }
        }
    }
}

/// Two editor panes side by side, with a draggable divider. Built by hand for the same
/// reason as `OutlineSplit`. The split is kept as a fraction, so it holds as the window resizes.
private struct PaneSplit<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @AppStorage("editorSplitFraction") private var fraction = 0.5
    @State private var dragStartWidth: Double?

    private let minPane = 280.0

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let maxLeading = max(minPane, total - minPane)
            let width = min(max(total * fraction, minPane), maxLeading)
            HStack(spacing: 0) {
                leading
                    .frame(width: width)
                Divider()
                trailing
                    .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .topLeading) {
                SplitHandle(axis: .horizontal) {
                    dragStartWidth = width
                } onDrag: { distance in
                    let start = dragStartWidth ?? width
                    let newWidth = min(max(start + distance, minPane), maxLeading)
                    if total > 0 { fraction = newWidth / total }
                } onEnd: {
                    dragStartWidth = nil
                } onDoubleClick: {
                    fraction = 0.5
                }
                .frame(width: SplitHandle.thickness, height: geometry.size.height)
                .offset(x: width + 0.5 - SplitHandle.thickness / 2)
            }
        }
    }
}

/// The selected drafts' outlines, stacked, each labeled with its file (SPEC.md §9).
private struct PinnedOutlinePane: View {
    let model: ProjectModel
    let pane: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OUTLINE")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    model.outlinePinned = false
                } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .help("Unpin Outline (⌥⌘O)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()
            EditorView(model: model, mode: .outlines, pane: pane)
        }
    }
}

struct EditorView: NSViewRepresentable {
    let model: ProjectModel
    let mode: EditorMode
    let pane: Int

    func makeCoordinator() -> EditorController {
        EditorController(mode: mode, pane: pane)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(with: model, mode: mode)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorController) {
        coordinator.detach()
    }
}
