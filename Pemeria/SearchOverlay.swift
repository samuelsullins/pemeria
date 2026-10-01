import AppKit
import PemeriaCore
import SwiftUI

/// ⌘K: search everything (SPEC.md §12). Type to see results grouped by kind; arrow keys move,
/// Return jumps, Esc or a click outside closes.
struct SearchOverlay: View {
    let model: ProjectModel
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var selected = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                    model.focusEditor()
                }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    SearchField(
                        text: $query,
                        onMove: move,
                        onSubmit: { open(selected) },
                        onCancel: {
                            close()
                            model.focusEditor()
                        }
                    )
                    .frame(height: 24)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if !results.isEmpty {
                    Divider()
                    resultList
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Divider()
                    Text("No matches")
                        .foregroundStyle(.secondary)
                        .padding(18)
                }
            }
            .frame(width: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 56)
        }
        .onChange(of: query) {
            results = model.project.search(query)
            selected = 0
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        if index == 0 || results[index - 1].kind != result.kind {
                            Text(result.kind.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .kerning(1.1)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, index == 0 ? 8 : 12)
                                .padding(.bottom, 4)
                        }
                        ResultRow(result: result, isSelected: index == selected)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { open(index) }
                            .onHover { if $0 { selected = index } }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
            .onChange(of: selected) { _, index in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
            }
        }
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(selected + step, 0), results.count - 1)
    }

    private func open(_ index: Int) {
        guard results.indices.contains(index) else { return }
        let result = results[index]
        close()
        model.open(result)
    }

    private func close() {
        model.isSearching = false
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(for: result.kind))
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 16)
            Text(highlighted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if result.kind != .fileName {
                Text(result.fileTitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Theme.accentColor : Color.clear))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 6)
    }

    /// The snippet with the match in bold.
    private var highlighted: AttributedString {
        let text = result.snippet as NSString
        let range = result.matchRange
        guard NSMaxRange(range) <= text.length else { return AttributedString(result.snippet) }
        var before = AttributedString(text.substring(to: range.location))
        var match = AttributedString(text.substring(with: range))
        var after = AttributedString(text.substring(from: NSMaxRange(range)))
        match.inlinePresentationIntent = .stronglyEmphasized
        if !isSelected { match.foregroundColor = Theme.accentColor }
        if result.kind == .comment {
            before.foregroundColor = isSelected ? .white : .secondary
            after.foregroundColor = isSelected ? .white : .secondary
        }
        return before + match + after
    }

    static func symbol(for kind: SearchResult.Kind) -> String {
        switch kind {
        case .fileName: "doc"
        case .draft: "text.alignleft"
        case .note: "note.text"
        case .outline: "list.bullet.indent"
        case .comment: "text.bubble"
        case .bookmark: "bookmark.fill"
        }
    }
}

/// A plain text field that reports ↑/↓, Return and Esc, and takes focus as soon as it appears.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search files, drafts, outlines, notes, comments and bookmarks"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
