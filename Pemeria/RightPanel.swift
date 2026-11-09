import PemeriaCore
import SwiftUI

/// Comments above, bookmarks below (SPEC.md §6–7); or search, while it's open (§12).
struct RightPanel: View {
    let model: ProjectModel

    var body: some View {
        if model.isSearching {
            SearchPanel(model: model)
        } else {
            VerticalSplit(heightKey: "bookmarksPaneHeight", defaultHeight: 260, minTop: 140, minBottom: 120) {
                CommentsSection(model: model)
            } bottom: {
                BookmarksSection(model: model)
            }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    /// How to make one, shown as a key cap after the title: `//` for comments, `#` for bookmarks.
    var hint: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.headline).lineLimit(1)
            if let hint { ShortcutHint(keys: hint) }
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
    @State private var filter = ""

    var body: some View {
        let scope = showAll ? Set(model.project.files.keys) : Set(model.selection)
        let all = model.project.comments(in: scope)
        let comments = all.filter { PanelFilterField.matches(filter, $0.text, title(of: $0.location)) }
        VStack(spacing: 0) {
            SectionHeader(title: "Comments", hint: "//") {}
            Divider()
            WideSwitch(selection: $showAll, options: [("Selected Files", false), ("All Files", true)])
                .padding(.horizontal, 12)
                .padding(.top, 8)
            PanelFilterField(prompt: "Filter Comments", text: $filter)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if comments.isEmpty, !all.isEmpty {
                EmptyPanelNote(text: "No comments match “\(filter)”.")
            } else if comments.isEmpty {
                EmptyPanelNote(text: "Type // in the text to leave a comment. It runs to the end of the line; end it early, or carry it over several lines, with \\.")
            } else {
                PanelList(comments) { comment in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // Ticking it off writes `//x` into the text, so it's saved like any edit.
                        Button {
                            model.setCommentDone(comment, !comment.isDone)
                        } label: {
                            Image(systemName: comment.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(comment.isDone ? Theme.accentColor : Color.secondary)
                                .frame(width: 16)
                        }
                        .buttonStyle(.borderless)
                        .help(comment.isDone ? "Mark as not done" : "Mark as done (//x)")
                        Button {
                            model.jump(to: comment.location)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(comment.text.isEmpty ? "(empty comment)" : comment.text)
                                    .strikethrough(comment.isDone)
                                    .foregroundStyle(comment.isDone ? Color.secondary : Color.primary)
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
                }
            }
        }
    }

    private func caption(for location: TextLocation) -> String {
        let title = title(of: location)
        return location.inOutline ? "\(title) · Outline" : title
    }

    private func title(of location: TextLocation) -> String {
        model.project.files[location.fileID]?.title ?? ""
    }
}

/// Every `#` bookmark in the project, in book order (SPEC.md §7). They're text, so they're
/// renamed or removed by editing them where they are.
private struct BookmarksSection: View {
    let model: ProjectModel
    @State private var filter = ""

    private func caption(for location: TextLocation) -> String {
        let title = model.project.files[location.fileID]?.title ?? ""
        return location.inOutline ? "\(title) · Outline" : title
    }

    var body: some View {
        let all = model.project.bookmarks()
        let bookmarks = all.filter {
            PanelFilterField.matches(filter, $0.name, model.project.files[$0.location.fileID]?.title ?? "")
        }
        VStack(spacing: 0) {
            SectionHeader(title: "Bookmarks", hint: "#") {}
            Divider()
            if !all.isEmpty {
                PanelFilterField(prompt: "Filter Bookmarks", text: $filter)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            if bookmarks.isEmpty, !all.isEmpty {
                EmptyPanelNote(text: "No bookmarks match “\(filter)”.")
            } else if bookmarks.isEmpty {
                EmptyPanelNote(text: "Type # in the text to bookmark a spot. It runs to the end of the line, or end it early with \\.")
            } else {
                PanelList(bookmarks) { entry in
                    // Laid out like a comment: the icon in its own column, the name and file
                    // lined up beside it.
                    Button {
                        model.jump(to: entry.location)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(Theme.accentColor)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name.isEmpty ? "Bookmark" : entry.name)
                                    .lineLimit(3)
                                Text(caption(for: entry.location))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// A scrolling list of rows in plain SwiftUI. Not `List`: on the Mac that's a table with a
/// separate SwiftUI host in every row, and dragging the panel's edge made those hosts re-lay
/// themselves out over and over until AppKit gave up and crashed the app.
struct PanelList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    let row: (Data.Element) -> Row

    init(_ data: Data, @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.row = row
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(data) { element in
                    row(element)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A two-way switch as wide as the filter field below it, in the same rounded shape.
struct WideSwitch<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(title: String, value: Value)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}

/// A small filter field over a panel's list: keeps the rows whose words or file name contain
/// what's typed (ignoring case and accents).
struct PanelFilterField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }

    static func matches(_ filter: String, _ fields: String...) -> Bool {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
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
