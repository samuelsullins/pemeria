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
                if model.outlinePinned {
                    VSplitView {
                        EditorView(model: model, mode: .bodies)
                            .frame(minHeight: 160)
                        PinnedOutlinePane(model: model, hasOutlines: files.contains { $0.kind == .draft })
                            .frame(minHeight: 110, idealHeight: 220)
                    }
                } else {
                    EditorView(model: model, mode: .full)
                }
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
