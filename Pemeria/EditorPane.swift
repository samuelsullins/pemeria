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
                Text(files.map(\.title).joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
            }
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
