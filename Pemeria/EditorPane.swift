import AppKit
import PemeriaCore
import SwiftUI

/// The right-hand side of the window: the file name(s), then the editor.
struct EditorPane: View {
    let model: ProjectModel

    var body: some View {
        let selected = Set(model.selection)
        let titles = model.project.tree.bookOrder.filter(selected.contains).compactMap { model.project.files[$0]?.title }
        if titles.isEmpty {
            ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Select a file in the sidebar."))
        } else {
            VStack(spacing: 0) {
                Text(titles.joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
                EditorView(model: model)
            }
        }
    }
}

struct EditorView: NSViewRepresentable {
    let model: ProjectModel

    func makeCoordinator() -> EditorController {
        EditorController()
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.sync(with: model)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: EditorController) {
        coordinator.detach()
    }
}
