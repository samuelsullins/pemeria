import AppKit
import PemeriaCore
import SwiftUI

/// Browse a file's snapshots and put an old version back (SPEC.md §11).
struct SnapshotBrowser: View {
    let model: ProjectModel
    let fileID: FileID
    @State private var versions: [SavedVersion] = []
    /// nil means the current text.
    @State private var selected: SavedVersion?
    @State private var preview: PemeriaFile?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let title = model.project.files[fileID]?.title ?? "File"
        VStack(spacing: 0) {
            Text("Snapshots of “\(title)”")
                .font(.headline)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                List(selection: Binding(
                    get: { selected?.id ?? Self.currentID },
                    set: { id in selected = versions.first { $0.id == id } }
                )) {
                    Text("Current Text").tag(Self.currentID)
                    if versions.isEmpty {
                        Text("No snapshots yet. They’re taken as you write, at most every 10 minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(versions) { version in
                        Text(version.date, format: .dateTime.weekday(.abbreviated).day().month().hour().minute())
                            .tag(version.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                Divider()
                DocumentPreview(file: preview)
            }
            Divider()
            HStack {
                Text("Restoring keeps a snapshot of the current text, so nothing is lost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore This Version") {
                    if let selected { model.restore(selected, of: fileID) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
            .padding(14)
        }
        .frame(width: 760, height: 540)
        .onAppear {
            versions = model.package.versions(of: fileID)
            loadPreview()
        }
        .onChange(of: selected) { loadPreview() }
    }

    private static let currentID = URL(filePath: "/current")

    private func loadPreview() {
        if let selected {
            preview = try? model.package.read(selected, of: fileID)
        } else {
            model.commitEditors()
            preview = model.project.files[fileID]
        }
    }
}

/// The project's trash: restore files, or empty it for good (SPEC.md §11).
struct TrashBrowser: View {
    let model: ProjectModel
    @State private var entries: [TrashedFile] = []
    @State private var selected: URL?
    @State private var confirmingEmpty = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entry = entries.first { $0.id == selected }
        VStack(spacing: 0) {
            Text("Trash")
                .font(.headline)
                .padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                List(selection: $selected) {
                    if entries.isEmpty {
                        Text("The trash is empty.")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(entry.file.title, systemImage: entry.file.kind == .note ? "note.text" : "doc.text")
                            Text("Trashed \(entry.date, format: .dateTime.day().month().hour().minute())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 230)
                Divider()
                DocumentPreview(file: entry?.file)
            }
            Divider()
            HStack {
                Button("Empty Trash…", role: .destructive) { confirmingEmpty = true }
                    .disabled(entries.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") {
                    if let entry {
                        model.restoreFromTrash(entry)
                        reload()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry == nil)
            }
            .padding(14)
        }
        .frame(width: 760, height: 540)
        .onAppear(perform: reload)
        .confirmationDialog("Permanently delete \(entries.count == 1 ? "1 file" : "\(entries.count) files") in the trash?",
                            isPresented: $confirmingEmpty) {
            Button("Empty Trash", role: .destructive) {
                model.emptyTrash()
                reload()
            }
        } message: {
            Text("This can’t be undone. Their snapshots are deleted too.")
        }
    }

    private func reload() {
        entries = model.package.trashedFiles()
        if !entries.contains(where: { $0.id == selected }) { selected = entries.first?.id }
    }
}

/// A read-only look at a file: its text, then its outline, with italics, bold and greyed comments.
struct DocumentPreview: View {
    let file: PemeriaFile?

    var body: some View {
        ScrollView {
            if let file {
                VStack(alignment: .leading, spacing: 18) {
                    Text(Self.text(file.body))
                        .lineSpacing(4)
                    if file.kind == .draft, let outline = file.outline, !outline.isEmpty {
                        Text("OUTLINE")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(1.2)
                            .foregroundStyle(.tertiary)
                        Text(Self.text(outline))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                    }
                }
                .font(.system(size: 14, design: .serif))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    static func text(_ blocks: [Block]) -> AttributedString {
        var result = AttributedString()
        var first = true
        let paragraphs = blocks.compactMap { block -> Paragraph? in
            if case .paragraph(let paragraph) = block { return paragraph }
            return nil
        }
        for (paragraph, comments) in zip(paragraphs, Comments.annotations(inLines: paragraphs.map(\.text))) {
            if !first { result += AttributedString("\n") }
            first = false
            var line = AttributedString()
            for run in paragraph.runs {
                var piece = AttributedString(run.text)
                var intent: InlinePresentationIntent = []
                if run.style.contains(.italic) { intent.insert(.emphasized) }
                if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                line += piece
            }
            for comment in comments.map(\.range) {
                guard let range = Range(comment, in: line) else { continue }
                line[range].foregroundColor = .secondary
            }
            result += line
        }
        return result
    }
}
