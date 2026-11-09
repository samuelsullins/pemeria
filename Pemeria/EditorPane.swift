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
        // While split, the active pane wears an accent bar along its top.
        let isActive = model.isSplit && model.activePane == pane
        Group {
            if files.isEmpty {
                ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Select a file in the sidebar."))
                    .contentShape(Rectangle())
                    .onTapGesture { model.activate(pane: pane) }
                    .overlay(alignment: .topTrailing) {
                        // Nothing to split without a file; while split, the × closes this empty pane.
                        if model.isSplit {
                            SplitButton(model: model, pane: pane, compact: false)
                                .padding(.trailing, 12)
                                .padding(.top, 9)
                        }
                    }
            } else {
                VStack(spacing: 0) {
                    EditorHeader(model: model, pane: pane, files: files)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { model.activate(pane: pane) })
                    Divider()
                    let hasDrafts = files.contains { $0.kind == .draft }
                    let reading = model.isReading(pane: pane)
                    let outlineView = model.isOutlineView(pane: pane)
                    if outlineView, !hasDrafts {
                        Text("Notes don’t have outlines.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // One editor whatever the mode, so pinning the outline (or any other switch)
                        // keeps the same text view and your place in it, rather than starting over.
                        // Notes have no outline, so there's no pane to pin for them.
                        let pinned = model.isOutlinePinned(pane: pane)
                        let mode: EditorMode = reading ? .reading : outlineView ? .outlineView : pinned ? .bodies : .full
                        VerticalSplit(showsBottom: !reading && !outlineView && pinned && hasDrafts,
                                      heightKey: "outlinePaneHeight", defaultHeight: 220, minTop: 160, minBottom: 90) {
                            EditorView(model: model, mode: mode, pane: pane)
                        } bottom: {
                            PinnedOutlinePane(model: model, pane: pane)
                        }
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
        // Words and their shortcuts when there's room; then just the words; then the old icons
        // in a narrow pane (a split, say).
        ViewThatFits(in: .horizontal) {
            row(compact: false, hints: true)
            row(compact: false, hints: false)
            row(compact: true, hints: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(compact: Bool, hints: Bool) -> some View {
        HeaderLayout {
            HStack(spacing: compact ? 10 : 14) {
                ReadModeButton(model: model, pane: pane, compact: compact, hint: hints)
                CopyMenu(model: model, files: files, compact: compact)
                IndentButton(model: model, files: files, compact: compact)
            }
            .fixedSize()
            title
            HStack(spacing: compact ? 10 : 14) {
                // Too crushed for words, too crushed for the switch: ⇧⌘O and the View menu
                // still switch views.
                if !compact {
                    HStack(spacing: 4) {
                        DraftOutlineToggle(model: model, pane: pane)
                        if hints { ShortcutHint(keys: "⇧⌘O") }
                    }
                }
                SplitButton(model: model, pane: pane, compact: compact, hint: hints)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var title: some View {
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
}

/// The header's three parts: buttons at each end and the title centred in the pane, or in the
/// gap between the buttons when it would run into them.
private struct HeaderLayout: Layout {
    private let spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: proposal.width ?? ideal, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let left = subviews[0].sizeThatFits(.unspecified)
        let right = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        let gapStart = bounds.minX + left.width + spacing
        let gapEnd = bounds.maxX - right.width - spacing
        let room = max(0, gapEnd - gapStart)
        let width = min(subviews[1].sizeThatFits(.unspecified).width, room)
        let centred = bounds.midX - width / 2
        let x = min(max(centred, gapStart), gapEnd - width)
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
    }
}

/// A button's keyboard shortcut, drawn small like a key cap: ⇧⌘R. Always gray: fixed system
/// colours rather than `.tertiary` and friends, which inside a button turn into shades of the
/// accent blue.
struct ShortcutHint: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .labelColor).opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .labelColor).opacity(0.1), lineWidth: 0.5))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// Read mode on or off for this pane (SPEC.md §12).
private struct ReadModeButton: View {
    let model: ProjectModel
    let pane: Int
    let compact: Bool
    var hint = false

    var body: some View {
        let reading = model.isReading(pane: pane)
        Button {
            model.toggleReadMode(pane: pane)
        } label: {
            if compact {
                // On: full strength rather than the accent, so the header stays quiet.
                Image(systemName: "eye.fill")
                    .foregroundStyle(reading ? Color.primary : Color.secondary)
                    .frame(width: 18)
            } else {
                HeaderWordButton(title: "Read Mode", shortcut: hint ? "⇧⌘R" : nil, isOn: reading)
            }
        }
        .buttonStyle(.plain)
        .help(reading ? "Exit Read Mode (⇧⌘R)" : "Read Mode (⇧⌘R): hide comments, outlines and bookmarks")
    }
}

/// Copy ▾: the shown files' manuscript, their outlines, or both (SPEC.md §12).
private struct CopyMenu: View {
    let model: ProjectModel
    let files: [PemeriaFile]
    let compact: Bool
    @State private var copied = false

    var body: some View {
        let ids = files.map(\.id)
        Menu {
            Button("Just Manuscript") { copy(.manuscript, ids) }
            Button("Just Outlines") { copy(.outlines, ids) }
                .disabled(!model.hasOutlineText(ids))
            Button("Outlines + Manuscript") { copy(.both, ids) }
        } label: {
            if compact {
                Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                    .foregroundStyle(Color.secondary)
            } else {
                HeaderWordButton(title: copied ? "Copied" : "Copy")
            }
        }
        // A plain button rather than the borderless menu style, which tints its label with the
        // accent colour: this way it's the same gray as the other header words.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(files.count == 1 ? "Copy this file’s text" : "Copy the text of all \(files.count) files")
    }

    private func copy(_ content: CopyContent, _ ids: [FileID]) {
        model.copy(content, of: ids)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
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

/// First-line indents on or off for the shown files (on when every one of them is indented).
/// Says what clicking does: "No Indent" while indented, "Use Indent" while not.
private struct IndentButton: View {
    let model: ProjectModel
    let files: [PemeriaFile]
    let compact: Bool

    var body: some View {
        let indented = files.allSatisfy(\.indents)
        let which = files.count == 1 ? "this file" : "these files"
        Button {
            model.setIndent(files.map(\.id), to: !indented)
        } label: {
            if compact {
                // On: full strength, like the Read mode eye.
                Image(systemName: "increase.indent")
                    .foregroundStyle(indented ? Color.primary : Color.secondary)
                    .frame(width: 18)
            } else {
                HeaderWordButton(title: indented ? "No Indent" : "Use Indent")
            }
        }
        .buttonStyle(.plain)
        .help(indented ? "Indenting \(which). Click to stop indenting \(which)."
                       : "Not indenting \(which). Click to indent \(which).")
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
                .foregroundStyle(selected ? Theme.buttonOn : Theme.buttonGray)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.segmentFill : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Splits the editor in two; while split, closes this pane.
private struct SplitButton: View {
    let model: ProjectModel
    let pane: Int
    var compact = true
    var hint = false

    var body: some View {
        Button {
            if model.isSplit { model.closePane(pane) } else { model.toggleSplit() }
        } label: {
            // Closing a pane is always an ×: everyone knows what that does.
            if compact || model.isSplit {
                Image(systemName: model.isSplit ? "xmark" : "rectangle.split.2x1.fill")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            } else {
                HeaderWordButton(title: "Split View", shortcut: hint ? "⌘\\" : nil)
            }
        }
        .buttonStyle(.plain)
        .help(model.isSplit ? "Close This Pane" : "Split View (⌘\\)")
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
        .overlay(alignment: .leading) {
            // Once per window: in the left (or only) pane.
            if pane == 0 {
                SaveStatus(model: model)
                    .padding(.leading, 12)
            }
        }
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

/// "✓ Saved just now" at the foot of the editor, quiet like the word count, so you can see your
/// words are on disk. Orange if a save failed (it's retried with the next change, or ⌘S).
private struct SaveStatus: View {
    let model: ProjectModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            Group {
                if !model.unsaved.isEmpty {
                    Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .help("Some changes couldn’t be written to disk. They’re still here; Pemeria tries again with your next change, or press ⌘S.")
                } else {
                    Label(Self.text(since: model.lastSavedAt, now: context.date), systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                        .help("Pemeria saves as you write, a second after you pause.")
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .labelStyle(SpacedLabelStyle())
        }
    }

    static func text(since saved: Date?, now: Date) -> String {
        guard let saved else { return "Saved" }
        let seconds = Int(now.timeIntervalSince(saved))
        switch seconds {
        case ..<60: return "Saved just now"
        case ..<3600: return "Saved \(seconds / 60) min ago"
        default: return "Saved at \(saved.formatted(date: .omitted, time: .shortened))"
        }
    }
}

private struct SpacedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// The bar that drops in at the top of the window on ⌘S: Pemeria has already saved everything.
struct SaveConfirmationBar: View {
    let model: ProjectModel
    @State private var showing = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let failed = !model.unsaved.isEmpty
        VStack {
            if showing {
                HStack(spacing: 7) {
                    Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(Color(nsColor: failed ? .systemOrange : .systemGreen))
                    Text(failed ? "Some changes couldn’t be saved" : "Autosave is always on")
                        .fontWeight(.semibold)
                    if failed {
                        Text("Pemeria will keep trying")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.top, 44)
        .allowsHitTesting(false)
        .onChange(of: model.saveConfirmation) {
            withAnimation(.spring(duration: 0.3)) { showing = true }
            hideTask?.cancel()
            hideTask = Task {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.4)) { showing = false }
            }
        }
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

/// One view above another with a draggable divider, the lower one's height remembered under
/// `heightKey`: the editor and the pinned outline pane, or comments and bookmarks. (SwiftUI's
/// VSplitView crashed in both places: its split view and the views inside fought over layout.)
struct VerticalSplit<Top: View, Bottom: View>: View {
    /// False: just the top, full height. The top stays the same view either way.
    let showsBottom: Bool
    let top: Top
    let bottom: Bottom
    @AppStorage private var paneHeight: Double
    @State private var dragStartHeight: Double?

    private let minTop: Double
    private let minPane: Double

    init(showsBottom: Bool = true, heightKey: String, defaultHeight: Double, minTop: Double, minBottom: Double,
         @ViewBuilder top: () -> Top, @ViewBuilder bottom: () -> Bottom) {
        self.showsBottom = showsBottom
        self.top = top()
        self.bottom = bottom()
        _paneHeight = AppStorage(wrappedValue: defaultHeight, heightKey)
        self.minTop = minTop
        minPane = minBottom
    }

    var body: some View {
        GeometryReader { geometry in
            let maxPane = max(minPane, geometry.size.height - minTop)
            let height = min(max(paneHeight, minPane), maxPane)
            VStack(spacing: 0) {
                top
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsBottom {
                    Divider()
                    bottom
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsBottom {
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
}

/// Two editor panes side by side, with a draggable divider. Built by hand for the same
/// reason as `VerticalSplit`. The split is kept as a fraction, so it holds as the window resizes.
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
            // Headed like Documents, Comments, Bookmarks and Labels.
            SectionHeader(title: "Outline") {
                Button {
                    model.setOutlinePinned(false, pane: pane)
                } label: {
                    // Gray like the editor header's words: a plain button, which doesn't tint.
                    HeaderWordButton(title: "Unpin Outline", shortcut: "⌥⌘O")
                }
                .buttonStyle(.plain)
                .help("Put the outlines back under each file (⌥⌘O)")
            }
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
