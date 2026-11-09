import AppKit
import PemeriaCore
import SwiftUI

/// ⌘F: search everything, in the right panel (SPEC.md §12). Type to see results grouped by
/// kind; ↑/↓ move, Return or a click jumps (search stays open), Esc clears then closes.
/// ⌥⌘F (or the chevron) shows Replace: each result previews the change and can be left out.
struct SearchPanel: View {
    let model: ProjectModel
    @State private var selected = 0
    /// Results left out of Replace, by id.
    @State private var excluded: Set<String> = []
    @AppStorage("searchMatchCase") private var matchCase = false
    @AppStorage("searchWholeWords") private var wholeWords = false
    @AppStorage("searchWordForms") private var wordForms = false
    @AppStorage("replacePreservesCase") private var preserveCase = true
    @FocusState private var queryFocused: Bool
    @State private var querySelection: TextSelection?

    /// Results shown per kind; Replace still covers them all.
    private static let shownPerKind = 50

    private var options: SearchOptions {
        SearchOptions(matchCase: matchCase, wholeWords: wholeWords, wordForms: wordForms, scope: model.searchScopeFiles)
    }

    var body: some View {
        let options = options
        let all = model.project.search(model.searchQuery, options: options, wordForms: model.wordForms,
                                       limit: model.showReplace ? .max : Self.shownPerKind)
        let results = Self.capped(all)
        let terms = Project.searchTerms(model.searchQuery)
        let replaceBlocker: String? = terms.count > 1 ? "Replace works on one term at a time, not searches with several terms joined by +."
            : wordForms ? "Turn off Word Forms to replace. Otherwise “ran” would be replaced with the exact word you typed."
            : nil
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        model.showReplace.toggle()
                    } label: {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Theme.buttonGray)
                            .rotationEffect(.degrees(model.showReplace ? 90 : 0))
                            .frame(width: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(model.showReplace ? "Hide Replace" : "Show Replace (⌥⌘F)")
                    TextField("Search Everything", text: Binding(get: { model.searchQuery }, set: { model.searchQuery = $0 }),
                              selection: $querySelection)
                        .textFieldStyle(.roundedBorder)
                        .focused($queryFocused)
                        .onSubmit { open(results, selected) }
                        .onKeyPress(.downArrow) { move(1, in: results) }
                        .onKeyPress(.upArrow) { move(-1, in: results) }
                        .onKeyPress(.escape) {
                            // Esc clears the search first, then closes it.
                            if model.searchQuery.isEmpty { model.endSearch() } else { model.searchQuery = "" }
                            return .handled
                        }
                        .onChange(of: model.searchFocusRequest, initial: true) {
                            queryFocused = true
                            let query = model.searchQuery
                            querySelection = TextSelection(range: query.startIndex..<query.endIndex)
                        }
                    Button {
                        model.endSearch()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.buttonGray)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Search (Esc)")
                }
                if model.showReplace {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 12, height: 1)
                        TextField("Replace with", text: Binding(get: { model.replaceText }, set: { model.replaceText = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 12, height: 1)
                        Toggle("Preserve case", isOn: $preserveCase)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .disabled(matchCase)
                            .help("bob → dave, Bob → Dave, BOB → DAVE. Off when Match Case is on.")
                        Spacer(minLength: 4)
                        let count = all.count - all.filter { excluded.contains($0.id) }.count
                        Button(count == 0 ? "Replace" : "Replace \(count)") {
                            model.replaceAll(model.searchQuery, options: options, excluding: excluded,
                                             preservingCase: preserveCase && !matchCase)
                            excluded = []
                        }
                        .controlSize(.small)
                        .disabled(count == 0 || replaceBlocker != nil)
                        .help(replaceBlocker ?? "Replace every ticked match. Each changed file is saved to History first.")
                    }
                }
                OptionChips(matchCase: $matchCase, wholeWords: $wholeWords, wordForms: $wordForms)
                HStack(spacing: 6) {
                    ScopeMenu(model: model)
                    Spacer(minLength: 4)
                    if !terms.isEmpty {
                        Text(all.count == 1 ? "1 match" : model.showReplace || results.count == all.count ? "\(all.count) matches" : "\(all.count)+ matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()

            if let record = model.lastReplace {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentColor)
                    Text("Replaced \(record.count) in \(record.after.count) \(record.after.count == 1 ? "file" : "files").")
                        .font(.callout)
                    Spacer(minLength: 4)
                    Button("Undo") { model.undoReplace() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.accentColor.opacity(0.08))
                Divider()
            }

            if let replaceBlocker, model.showReplace, !results.isEmpty {
                Text(replaceBlocker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if results.isEmpty {
                Text(terms.isEmpty
                     ? "Search file names, drafts, outlines, notes, comments and bookmarks."
                     : "No matches")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                let preview = model.showReplace && replaceBlocker == nil
                    ? Preview(replacement: model.replaceText, preservingCase: preserveCase && !matchCase) : nil
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
                                ResultRow(
                                    result: result,
                                    isSelected: index == selected,
                                    preview: preview,
                                    isIncluded: !excluded.contains(result.id),
                                    toggleIncluded: {
                                        if excluded.contains(result.id) { excluded.remove(result.id) } else { excluded.insert(result.id) }
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selected = index
                                    open(results, index)
                                }
                            }
                            if results.count < all.count {
                                Text("Showing the first \(Self.shownPerKind) of each kind. Replace covers all \(all.count).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: selected) { _, index in
                        guard results.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .onChange(of: model.searchQuery) {
            selected = 0
            excluded = []
        }
        .onChange(of: options) { excluded = [] }
    }

    /// At most `shownPerKind` results of each kind.
    private static func capped(_ results: [SearchResult]) -> [SearchResult] {
        var counts: [SearchResult.Kind: Int] = [:]
        return results.filter { result in
            counts[result.kind, default: 0] += 1
            return counts[result.kind]! <= shownPerKind
        }
    }

    private func move(_ step: Int, in results: [SearchResult]) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selected = min(max(selected + step, 0), results.count - 1)
        return .handled
    }

    private func open(_ results: [SearchResult], _ index: Int) {
        guard results.indices.contains(index) else { return }
        model.open(results[index])
    }
}

/// What Replace would put in place of a match, for previewing in the results.
struct Preview {
    let replacement: String
    let preservingCase: Bool

    func text(replacing matched: String) -> String {
        preservingCase ? Project.matchingCase(of: matched, replacement) : replacement
    }
}

/// Match Case, Whole Words and Word Forms, as small toggles. Short labels when the panel is narrow.
private struct OptionChips: View {
    @Binding var matchCase: Bool
    @Binding var wholeWords: Bool
    @Binding var wordForms: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chips(["Match Case", "Whole Words", "Word Forms"])
            chips(["Aa", "Whole", "Forms"])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chips(_ labels: [String]) -> some View {
        HStack(spacing: 5) {
            Chip(label: labels[0], isOn: $matchCase, help: "Match Case: “lamp” doesn’t find “Lamp”.")
            Chip(label: labels[1], isOn: $wholeWords, help: "Whole Words: “Al” doesn’t find “Also”.")
            Chip(label: labels[2], isOn: $wordForms, help: "Word Forms: “run” also finds “ran” and “running”.")
        }
        .fixedSize()
    }
}

private struct Chip: View {
    let label: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(isOn ? Theme.buttonOn : Theme.buttonGray)
                .background(Capsule().fill(isOn ? Theme.segmentFill : Color(nsColor: .labelColor).opacity(0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// "In: Whole Project ▾": the whole project, just the notes, the selected files, or files with an icon.
private struct ScopeMenu: View {
    let model: ProjectModel

    var body: some View {
        Menu {
            Button("Whole Project") { model.searchScope = .project }
            Button("Just Notes") { model.searchScope = .notes }
            Button("Selected Files") { model.scopeSearchToSelection() }
                .disabled(model.selection.isEmpty)
            let icons = model.project.manifest.icons
            if !icons.isEmpty {
                Section("Files Marked") {
                    ForEach(icons) { icon in
                        Button {
                            model.searchScope = .icon(icon.id)
                        } label: {
                            Label(icon.name, systemImage: icon.symbol)
                        }
                    }
                }
            }
        } label: {
            Text("In: \(label)")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which files to search")
    }

    private var label: String {
        switch model.searchScope {
        case .project: return "Whole Project"
        case .notes: return "Just Notes"
        case .files(let ids):
            let count = ids.filter { model.project.files[$0] != nil }.count
            return count == 1 ? "1 File" : "\(count) Files"
        case .icon(let id):
            return model.project.manifest.icons.first { $0.id == id }?.name ?? "Whole Project"
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool
    /// Set while Replace is showing: the match is struck out with its replacement after it.
    let preview: Preview?
    let isIncluded: Bool
    let toggleIncluded: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if preview != nil {
                Button(action: toggleIncluded) {
                    Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.white : Theme.buttonGray)
                }
                .buttonStyle(.plain)
                .help(isIncluded ? "Leave this one out of Replace" : "Include this one in Replace")
            } else {
                Image(systemName: Self.symbol(for: result.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 14)
            }
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
            .opacity(preview != nil && !isIncluded && !isSelected ? 0.45 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Theme.accentColor : Color.clear))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 6)
    }

    /// The snippet with the matches in bold; while previewing Replace, the match struck out
    /// and followed by what replaces it.
    private var highlighted: AttributedString {
        let text = result.snippet as NSString
        let ranges = ([result.matchRange] + result.otherMatchRanges)
            .filter { NSMaxRange($0) <= text.length }
            .sorted { $0.location < $1.location }
        var output = AttributedString()
        var cursor = 0
        for range in ranges where range.location >= cursor {
            output += plain(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var match = AttributedString(text.substring(with: range))
            match.inlinePresentationIntent = .stronglyEmphasized
            if !isSelected { match.foregroundColor = Theme.accentColor }
            if let preview, isIncluded, range == result.matchRange {
                match.strikethroughStyle = .single
                match.inlinePresentationIntent = nil
                if !isSelected { match.foregroundColor = .secondary }
                var replacement = AttributedString(preview.text(replacing: result.matchedText))
                replacement.inlinePresentationIntent = .stronglyEmphasized
                if !isSelected { replacement.foregroundColor = Theme.accentColor }
                output += match + replacement
            } else {
                output += match
            }
            cursor = NSMaxRange(range)
        }
        output += plain(text.substring(from: cursor))
        return output
    }

    private func plain(_ string: String) -> AttributedString {
        var part = AttributedString(string)
        if result.kind == .comment, !isSelected { part.foregroundColor = .secondary }
        return part
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
