import PemeriaCore
import SwiftUI

/// Comments above, bookmarks below (SPEC.md §6–7).
struct RightPanel: View {
    let model: ProjectModel

    var body: some View {
        VSplitView {
            CommentsSection(model: model)
                .frame(minHeight: 120, idealHeight: 300)
            BookmarksSection(model: model)
                .frame(minHeight: 120, idealHeight: 260)
        }
    }
}

private struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct CommentsSection: View {
    let model: ProjectModel
    @AppStorage("commentsShowAll") private var showAll = false

    var body: some View {
        let scope = showAll ? Set(model.project.files.keys) : Set(model.selection)
        let comments = model.project.comments(in: scope)
        VStack(spacing: 0) {
            SectionHeader(title: "Comments") {
                Button {
                    NSApp.sendAction(#selector(EditorTextView.insertComment(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Start a comment at the cursor (⌘/)")
            }
            Picker("Show", selection: $showAll) {
                Text("Selected Files").tag(false)
                Text("All Files").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            if comments.isEmpty {
                EmptyPanelNote(text: "Type // in the text to leave a comment.")
            } else {
                List(comments) { comment in
                    Button {
                        model.jump(to: comment.location)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comment.text.isEmpty ? "(empty comment)" : comment.text)
                                .lineLimit(3)
                            Text(caption(for: comment.location))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    private func caption(for location: TextLocation) -> String {
        let title = model.project.files[location.fileID]?.title ?? ""
        return location.inOutline ? "\(title) · Outline" : title
    }
}

private struct BookmarksSection: View {
    let model: ProjectModel
    @State private var renaming: TextLocation?
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        let bookmarks = model.project.bookmarks()
        VStack(spacing: 0) {
            SectionHeader(title: "Bookmarks") {
                Button {
                    NSApp.sendAction(#selector(EditorTextView.addBookmark(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Bookmark the cursor’s line (⌘D)")
            }
            Divider()
            if bookmarks.isEmpty {
                EmptyPanelNote(text: "Press ⌘D in the text to bookmark a line.")
            } else {
                List(bookmarks) { entry in
                    row(entry)
                        .contextMenu {
                            Button("Rename") { startRenaming(entry) }
                            Button("Delete Bookmark") { model.removeBookmark(entry) }
                        }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: BookmarkEntry) -> some View {
        if renaming == entry.location {
            TextField("Name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit { finishRenaming(entry) }
                .onExitCommand { renaming = nil }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.bookmark.name.isEmpty ? "Bookmark" : entry.bookmark.name, systemImage: "bookmark.fill")
                    .labelStyle(.titleAndIcon)
                Text(model.project.files[entry.location.fileID]?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { startRenaming(entry) }
            .onTapGesture { model.jump(to: entry.location, bookmarkID: entry.bookmark.id) }
        }
    }

    private func startRenaming(_ entry: BookmarkEntry) {
        draftName = entry.bookmark.name
        renaming = entry.location
        nameFieldFocused = true
    }

    private func finishRenaming(_ entry: BookmarkEntry) {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        renaming = nil
        if !name.isEmpty, name != entry.bookmark.name {
            model.renameBookmark(entry, to: name)
        }
    }
}

private struct EmptyPanelNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
