import AppKit
import PemeriaCore
import SwiftUI

/// ⌘F: search everything, in the right panel (SPEC.md §12). Type to see results grouped by
/// kind; ↑/↓ move, Return or a click jumps (search stays open), Esc clears then closes.
struct SearchPanel: View {
    let model: ProjectModel
    @State private var selected = 0

    var body: some View {
        let results = model.project.search(model.searchQuery)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(
                    text: Binding(get: { model.searchQuery }, set: { model.searchQuery = $0 }),
                    focusRequest: model.searchFocusRequest,
                    onMove: { step in
                        guard !results.isEmpty else { return }
                        selected = min(max(selected + step, 0), results.count - 1)
                    },
                    onSubmit: { open(results, selected) },
                    onClose: model.endSearch
                )
                Button {
                    model.endSearch()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Search (Esc)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()

            if results.isEmpty {
                Text(model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Search file names, drafts, outlines, notes, comments and bookmarks."
                     : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                if index == 0 || results[index - 1].kind != result.kind {
                                    Text(result.kind.title.uppercased())
                                        .font(.system(size: 10, weight: .semibold))
                                        .kerning(1.1)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 8 : 14)
                                        .padding(.bottom, 4)
                                }
                                ResultRow(result: result, isSelected: index == selected)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selected = index
                                        open(results, index)
                                    }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: selected) { _, index in
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
                    }
                }
            }
        }
        .onChange(of: model.searchQuery) { selected = 0 }
    }

    private func open(_ results: [SearchResult], _ index: Int) {
        guard results.indices.contains(index) else { return }
        model.open(results[index])
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(for: result.kind))
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted)
                    .lineLimit(3)
                if result.kind != .fileName {
                    Text(result.fileTitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
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
        if result.kind == .comment, !isSelected {
            before.foregroundColor = .secondary
            after.foregroundColor = .secondary
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

/// A search field that reports ↑/↓, Return and Esc, and takes focus when asked.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search Everything"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Never overwrite the field while it's being typed in: SwiftUI can hand back a
        // value a keystroke behind, which used to drop letters mid-word.
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        if coordinator.focusedRequest != focusRequest {
            coordinator.focusedRequest = focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var focusedRequest: Int?

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
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc clears the search first, then closes it.
                if textView.string.isEmpty {
                    parent.onClose()
                } else {
                    textView.string = ""
                    parent.text = ""
                }
            default: return false
            }
            return true
        }
    }
}
