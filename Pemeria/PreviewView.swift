import PemeriaCore
import SwiftUI

/// A read-only view of the selected files. Placeholder until the real editor (build step 3).
struct PreviewView: View {
    let model: ProjectModel

    var body: some View {
        let selected = Set(model.selection)
        let ids = model.project.tree.bookOrder.filter(selected.contains)
        if ids.isEmpty {
            ContentUnavailableView("No File Selected", systemImage: "doc.text", description: Text("Select a file in the sidebar."))
        } else {
            VStack(spacing: 0) {
                Text(ids.compactMap { model.project.files[$0]?.title }.joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(ids, id: \.self) { id in
                            if let file = model.project.files[id] {
                                FilePreview(file: file)
                                if id != ids.last { DottedRule() }
                            }
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.vertical, 40)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct FilePreview: View {
    let file: PemeriaFile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            blocks(file.body)
            if file.kind == .draft, let outline = file.outline {
                Text("OUTLINE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                blocks(outline)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 16, design: .serif))
        .lineSpacing(5)
        .textSelection(.enabled)
    }

    private func blocks(_ blocks: [Block]) -> some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .paragraph(let paragraph):
                Text(attributed(paragraph))
            case .bookmark(let bookmark):
                Label(bookmark.name, systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    private func attributed(_ paragraph: Paragraph) -> AttributedString {
        var result = AttributedString()
        for run in paragraph.runs {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            piece.inlinePresentationIntent = intent
            result += piece
        }
        return result
    }
}

private struct DottedRule: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
            .foregroundStyle(.tertiary)
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}
