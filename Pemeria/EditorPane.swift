import AppKit
import PemeriaCore
import SwiftUI

/// The right-hand side of the window: the file name(s), the editor, and (when pinned) the outline pane.
struct EditorPane: View {
    let model: ProjectModel

    var body: some View {
        let selected = Set(model.selection)
        let files = model.project.tree.bookOrder.filter(selected.contains).compactMap { model.project.files[$0] }
        if files.isEmpty {
            ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Select a file in the sidebar."))
        } else {
            VStack(spacing: 0) {
                EditorHeader(model: model, files: files)
                Divider()
                if model.readMode {
                    EditorView(model: model, mode: .reading)
                } else if model.outlinePinned {
                    OutlineSplit {
                        EditorView(model: model, mode: .bodies)
                    } bottom: {
                        PinnedOutlinePane(model: model, hasOutlines: files.contains { $0.kind == .draft })
                    }
                } else {
                    EditorView(model: model, mode: .full)
                }
                Divider()
                WordCountBar(model: model)
            }
        }
    }
}

/// The file name above the editor, with the one-click copy button in its corner.
/// With one file selected the name is editable in place (SPEC.md §12).
private struct EditorHeader: View {
    let model: ProjectModel
    let files: [PemeriaFile]

    var body: some View {
        ZStack {
            if files.count == 1, let file = files.first {
                HeaderTitleField(model: model, file: file)
                    .id(file.id)
            } else {
                Text(files.map(\.title).joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48)
        .padding(.vertical, 8)
        .overlay(alignment: .trailing) {
            CopyButton(help: files.count == 1 ? "Copy Draft Text" : "Copy Draft Text of All \(files.count) Files") {
                model.copyDraftText(of: files.map(\.id))
            }
            .padding(.trailing, 12)
        }
    }
}

/// Click and type to rename. Return or clicking away saves; Esc puts the old name back.
private struct HeaderTitleField: View {
    let model: ProjectModel
    let file: PemeriaFile
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.headline)
            .multilineTextAlignment(.center)
            .focused($focused)
            .onAppear { text = file.title }
            .onChange(of: file.title) { _, title in
                if !focused { text = title }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { focused = false }
            // Clicking another file mid-rename removes this field before it loses focus.
            .onDisappear { commit() }
            .onExitCommand {
                text = file.title
                focused = false
            }
            .help("Click to rename")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == file.title {
            text = file.title
        } else {
            model.rename(file.id, to: trimmed)
        }
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
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
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
    @State private var showingDetails = false

    var body: some View {
        let counts = model.wordCounts
        let hasDrafts = model.selection.contains { model.project.files[$0]?.kind == .draft }
        Button {
            showingDetails.toggle()
        } label: {
            Text(hasDrafts ? Self.words(counts.selectedDraft) : "Notes aren’t counted")
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
                row("Selected Draft", counts.selectedDraft)
                row("Selected Outline", counts.selectedOutline)
                Divider()
                row("Total Draft", counts.totalDraft)
                row("Total Outline", counts.totalOutline)
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
                    .overlay {
                        Color.clear
                            .frame(height: 8)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = dragStartHeight ?? height
                                        dragStartHeight = start
                                        paneHeight = min(max(start - value.translation.height, minPane), maxPane)
                                    }
                                    .onEnded { _ in dragStartHeight = nil }
                            )
                    }
                bottom
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
    }
}

/// The selected drafts' outlines, stacked, each labeled with its file (SPEC.md §9).
private struct PinnedOutlinePane: View {
    let model: ProjectModel
    let hasOutlines: Bool

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
            if hasOutlines {
                EditorView(model: model, mode: .outlines)
            } else {
                Text("Notes don’t have outlines.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct EditorView: NSViewRepresentable {
    let model: ProjectModel
    let mode: EditorMode

    func makeCoordinator() -> EditorController {
        EditorController(mode: mode)
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
