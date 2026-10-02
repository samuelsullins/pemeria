import AppKit
import Observation
import PemeriaCore

/// One open project: the in-memory `Project`, what's selected and folded, and saving.
/// Every edit is written to disk straight away (the editor's typing after a 1-second pause).
@Observable
final class ProjectModel {
    let package: ProjectPackage
    private(set) var project: Project
    /// Bumped whenever the sidebar's contents change (names, kinds, structure). Not for typing.
    private(set) var revision = 0
    /// Bumped when only how rows look changes (icons, the Working File), so the sidebar
    /// refreshes rows in place rather than reloading (which would close an open icon popover).
    private(set) var appearanceRevision = 0
    /// Selected files, in book order: what the sidebar shows, and what the active editor
    /// pane shows.
    var selection: [FileID] = [] {
        willSet { commitEditors() }
        didSet { if selection != oldValue { saveState() } }
    }
    /// Parents whose children are showing.
    var expanded: Set<FileID> = [] {
        didSet { if expanded != oldValue { saveState() } }
    }
    /// Set to start renaming a file in the sidebar (e.g. right after creating it).
    var renameRequest: FileID?
    /// Where you were in each file.
    var positions: [FileID: FilePosition] = [:]
    /// Repairs made while loading, for the user to see once.
    let problems: [String]

    /// Outlines shown in the pinned pane below the editor instead of inline (SPEC.md §9).
    var outlinePinned = false {
        willSet { commitEditors() }
        didSet { if outlinePinned != oldValue { saveState() } }
    }

    /// The panes in Read mode (SPEC.md §12): comments, outlines and bookmarks hidden; not editable.
    /// Each pane has its own; unsplit, only pane 0 counts.
    private(set) var readingPanes: Set<Int> = [] {
        willSet { commitEditors() }
    }

    func isReading(pane: Int) -> Bool { readingPanes.contains(pane) }

    /// Read mode on or off for a pane; the active one by default.
    func toggleReadMode(pane: Int? = nil) {
        let pane = pane ?? activePane
        if readingPanes.contains(pane) {
            readingPanes.remove(pane)
        } else {
            // Read mode reads the draft, so it brings back Draft view.
            setOutlineView(false, pane: pane)
            readingPanes.insert(pane)
        }
    }

    /// The panes in Outline view: only the selected drafts' outlines, each under its file's name.
    /// Each pane has its own, like Read mode.
    private(set) var outlinePanes: Set<Int> = [] {
        willSet { commitEditors() }
    }

    func isOutlineView(pane: Int) -> Bool { outlinePanes.contains(pane) }

    /// Switches a pane (the active one by default) between Draft and Outline view.
    /// Outline view leaves Read mode, which only reads the draft.
    func setOutlineView(_ on: Bool, pane: Int? = nil) {
        let pane = pane ?? activePane
        guard outlinePanes.contains(pane) != on else { return }
        if on {
            if readingPanes.contains(pane) { readingPanes.remove(pane) }
            outlinePanes.insert(pane)
        } else {
            outlinePanes.remove(pane)
        }
    }

    /// Leaves Read mode in the active pane, e.g. before jumping somewhere to edit.
    private func exitReadModeInActivePane() {
        if readingPanes.contains(activePane) { readingPanes.remove(activePane) }
    }

    /// A comment or bookmark to move to, set by the right panel and cleared by the editor that shows it.
    var jumpRequest: JumpRequest?
    private var jumpCount = 0

    /// Bumped when a shown file's text is changed from outside the editor (e.g. renaming a
    /// bookmark in the panel), so editors reload it.
    private(set) var contentToken = 0

    // MARK: Split view (SPEC.md §12)

    /// Two editor panes side by side.
    private(set) var isSplit = false
    /// The pane the sidebar is driving (0 = left, 1 = right).
    private(set) var activePane = 0
    /// What the other pane shows while split.
    private(set) var otherSelection: [FileID] = []

    /// The files a pane shows, in book order.
    func selection(forPane pane: Int) -> [FileID] {
        pane == activePane || !isSplit ? selection : otherSelection
    }

    func toggleSplit() {
        commitEditors()
        if isSplit {
            // The active pane's files stay, and its Read mode and view with them.
            keepPaneState(ofPane: activePane)
            if activePane != 0 { activePane = 0 }
            isSplit = false
        } else {
            otherSelection = selection
            activePane = 0
            isSplit = true
        }
    }

    /// Closes one pane of the split; the other one stays and becomes the only pane.
    func closePane(_ pane: Int) {
        guard isSplit else { return }
        commitEditors()
        keepPaneState(ofPane: 1 - pane)
        if pane == activePane { selection = otherSelection }
        activePane = 0
        isSplit = false
    }

    /// Unsplitting: the pane that stays becomes pane 0, bringing its Read mode and Outline view.
    private func keepPaneState(ofPane pane: Int) {
        let reading: Set<Int> = readingPanes.contains(pane) ? [0] : []
        if readingPanes != reading { readingPanes = reading }
        let outline: Set<Int> = outlinePanes.contains(pane) ? [0] : []
        if outlinePanes != outline { outlinePanes = outline }
    }

    /// Makes a pane the active one; the sidebar then shows (and changes) its files.
    func activate(pane: Int) {
        guard isSplit, pane != activePane else { return }
        let current = selection
        activePane = pane
        selection = otherSelection
        otherSelection = current
    }

    // MARK: Search, snapshots and trash

    /// ⌘F search has taken over the right panel (SPEC.md §12).
    private(set) var isSearching = false
    var searchQuery = ""
    /// Bumped to put the cursor in the search field.
    private(set) var searchFocusRequest = 0
    /// Whether the right panel was hidden before search opened it, so closing search hides it again.
    @ObservationIgnored private var panelWasHidden = false

    func startSearch() {
        commitEditors()
        if !isSearching {
            panelWasHidden = !AppModel.shared.rightPanelVisible
            isSearching = true
        }
        AppModel.shared.rightPanelVisible = true
        searchFocusRequest += 1
    }

    func endSearch() {
        guard isSearching else { return }
        isSearching = false
        lastReplace = nil
        if panelWasHidden { AppModel.shared.rightPanelVisible = false }
        focusEditor()
    }

    func toggleSearch() {
        if isSearching { endSearch() } else { startSearch() }
    }

    /// ⌥⌘F: search with the Replace field showing.
    func startReplace() {
        showReplace = true
        startSearch()
    }

    /// The Replace field is showing under the search field.
    var showReplace = false
    var replaceText = ""
    /// Which files search looks in.
    var searchScope = SearchScope.project
    /// Dictionary forms of words, for Word Forms searches.
    @ObservationIgnored let wordForms = WordForms()

    /// The last Replace, so the search panel can offer to undo it.
    private(set) var lastReplace: ReplaceRecord?

    /// The files `searchScope` covers, or nil for the whole project.
    var searchScopeFiles: Set<FileID>? {
        switch searchScope {
        case .project: nil
        case .files(let ids): ids.filter { project.files[$0] != nil }
        case .icon(let id): Set(project.files.values.filter { $0.icons.contains(id) }.map(\.id))
        }
    }

    /// Search the selected files, and everything nested in them, from now on.
    func scopeSearchToSelection() {
        searchScope = .files(Set(selection.flatMap { [$0] + project.descendants(of: $0) }))
    }

    /// Replaces every match of the search except the `excluded` result ids (SPEC.md §12).
    /// Each changed file is snapshotted first, and the whole replace can be undone at once.
    func replaceAll(_ query: String, options: SearchOptions, excluding excluded: Set<String>, preservingCase: Bool) {
        commitEditors()
        let results = project.search(query, options: options, wordForms: wordForms, limit: .max)
            .filter { !excluded.contains($0.id) }
        let ids = Set(results.map(\.fileID))
        guard !ids.isEmpty else { return }
        let before = project.files.filter { ids.contains($0.key) }
        for id in ids {
            try? package.snapshot(id)
            lastSnapshot[id] = .now
        }
        let (changed, count) = project.replace(results, with: replaceText, preservingCase: preservingCase)
        guard !changed.isEmpty else { return }
        save(changed)
        contentToken += 1
        lastReplace = ReplaceRecord(before: changed.compactMap { before[$0.id] }, after: changed, count: count)
    }

    /// Puts back what the last Replace changed. A file edited since is left alone; its
    /// snapshot from just before the replace is in History.
    func undoReplace() {
        guard let record = lastReplace else { return }
        commitEditors()
        lastReplace = nil
        var restored: [PemeriaFile] = []
        var skipped: [String] = []
        for (old, new) in zip(record.before, record.after) {
            guard project.files[new.id] == new else {
                if let current = project.files[new.id] { skipped.append("“\(current.title)”") }
                continue
            }
            _ = project.setContent(old.id, body: old.body, outline: old.outline)
            _ = project.rename(old.id, to: old.title)
            if let file = project.files[old.id] { restored.append(file) }
        }
        save(restored)
        contentToken += 1
        if !skipped.isEmpty {
            AppModel.shared.message = "These files were edited after the replace, so they were left as they are: "
                + skipped.joined(separator: ", ")
                + ". Their text from just before the replace is in History."
        }
    }
    /// The file whose snapshots are being browsed.
    var historyFile: FileID?
    var isShowingTrash = false

    /// Goes to a search result.
    func open(_ result: SearchResult) {
        if let location = result.location {
            jump(to: location, bookmarkID: result.bookmarkID)
        } else {
            exitReadModeInActivePane()
            reveal(result.fileID)
            selection = [result.fileID]
            focusRequest += 1
        }
    }

    /// Puts an old version's text back. The current text is snapshotted first, so this can be undone
    /// by restoring that snapshot.
    func restore(_ version: SavedVersion, of id: FileID) {
        commitEditors()
        do {
            let old = try package.read(version, of: id)
            try package.snapshot(id)
            lastSnapshot[id] = .now
            guard let file = project.setContent(id, body: old.body, outline: old.outline) else { return }
            save([file], structural: false)
            contentToken += 1
        } catch {
            AppModel.shared.message = "Couldn’t restore that version.\n\n\(error.localizedDescription)"
        }
    }

    /// Takes a file out of the trash and selects it.
    func restoreFromTrash(_ entry: TrashedFile) {
        commitEditors()
        let changed = project.restore(entry.file)
        guard let restored = changed.first else { return }
        do {
            try package.restore(entry, as: restored)
        } catch {
            unsaved.insert(restored.id)
            AppModel.shared.message = "Couldn’t fully restore “\(restored.title)”. It’s back in the project; Pemeria will try saving it again on the next change.\n\n\(error.localizedDescription)"
        }
        save(Array(changed.dropFirst()))
        revision += 1
        reveal(restored.id)
        selection = [restored.id]
    }

    /// Permanently deletes everything in the trash.
    func emptyTrash() {
        do {
            try package.emptyTrash(keepingSnapshotsOf: Set(project.files.keys))
        } catch {
            AppModel.shared.message = "Couldn’t empty the trash.\n\n\(error.localizedDescription)"
        }
    }

    /// Bumped to open the Icons pane at the bottom of the sidebar (e.g. "Edit Icons…").
    private(set) var iconEditorRequest = 0

    /// Words in the editor's selected text, or nil when nothing is selected (SPEC.md §10).
    private(set) var selectedTextWords: Int?
    /// The pane the selected text is in.
    private(set) var selectedTextPane = 0
    @ObservationIgnored private var selectedTextSource: ObjectIdentifier?

    /// Open editors register here; each saves its unsaved typing and records the cursor.
    /// Called before anything that changes what an editor shows.
    @ObservationIgnored private var editorCommits: [ObjectIdentifier: () -> Void] = [:]

    func registerEditor(_ editor: AnyObject, commit: @escaping () -> Void) {
        editorCommits[ObjectIdentifier(editor)] = commit
    }

    func unregisterEditor(_ editor: AnyObject) {
        editorCommits[ObjectIdentifier(editor)] = nil
    }

    func commitEditors() {
        editorCommits.values.forEach { $0() }
    }

    private let isAccessingSecurityScope: Bool

    init(url: URL) throws {
        isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
        package = ProjectPackage(url: url)
        do {
            let loaded = try package.load()
            project = Project(loaded)
            problems = loaded.problems
        } catch {
            if isAccessingSecurityScope { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        if let state = package.loadState() {
            selection = state.selection.filter { project.files[$0] != nil }
            expanded = Set(state.expanded.filter { project.files[$0] != nil })
            outlinePinned = state.outlinePinned
            for (key, position) in state.positions {
                if let id = FileID(key), project.files[id] != nil { positions[id] = position }
            }
        }
    }

    func close() {
        commitEditors()
        saveState()
        if isAccessingSecurityScope { package.url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Edits

    /// Creates a file after `sibling` (default: the last selected file), selects it, and starts renaming it.
    func newFile(kind: FileKind, after sibling: FileID? = nil) {
        commitEditors()
        let file = project.createFile(kind: kind, after: sibling ?? selection.last)
        save([file])
        if let parent = file.parent { expanded.insert(parent) }
        selection = [file.id]
        renameRequest = file.id
    }

    func rename(_ id: FileID, to title: String) {
        if let file = project.rename(id, to: title) { save([file]) }
    }

    func setKind(_ ids: [FileID], to kind: FileKind) {
        commitEditors()
        save(project.setKind(ids, to: kind))
    }

    /// Returns false if the move isn't allowed.
    @discardableResult
    func move(_ ids: [FileID], into parent: FileID?, at index: Int) -> Bool {
        commitEditors()
        guard let changed = project.move(ids, into: parent, at: index) else { return false }
        save(changed)
        if let parent { expanded.insert(parent) }
        return true
    }

    /// Moves files, and everything nested in them, into the project's trash folder.
    func trash(_ ids: [FileID]) {
        commitEditors()
        let workingFileBefore = project.manifest.workingFile
        let removed = project.remove(ids)
        var failures: [String] = []
        for id in removed {
            do { try package.moveToTrash(id) } catch { failures.append(error.localizedDescription) }
            positions[id] = nil
            wordCountCache[id] = nil
        }
        if project.manifest.workingFile != workingFileBefore {
            do { try package.writeManifest(project.manifest) } catch { failures.append(error.localizedDescription) }
        }
        selection.removeAll { removed.contains($0) }
        otherSelection.removeAll { removed.contains($0) }
        if let history = historyFile, removed.contains(history) { historyFile = nil }
        expanded.subtract(removed)
        revision += 1
        if !failures.isEmpty {
            AppModel.shared.message = "Some files couldn’t be moved to the trash. They’ll reappear next time the project opens.\n\n"
                + failures.joined(separator: "\n")
        }
    }

    /// Shows the file containing `location` (selecting it if needed) and moves the cursor there.
    func jump(to location: TextLocation, bookmarkID: String? = nil) {
        exitReadModeInActivePane()
        // Draft text isn't shown in Outline view.
        if !location.inOutline { setOutlineView(false) }
        if !selection.contains(location.fileID) {
            reveal(location.fileID)
            selection = [location.fileID]
        }
        jumpCount += 1
        jumpRequest = JumpRequest(id: jumpCount, location: location, bookmarkID: bookmarkID)
    }

    // MARK: Icons and the Working File

    /// Turns an icon on or off for `ids` (SPEC.md §4).
    func toggleIcon(_ iconID: String, on ids: [FileID]) {
        save(project.toggleIcon(iconID, on: ids), structural: false)
        appearanceRevision += 1
    }

    func showIconEditor() {
        iconEditorRequest += 1
    }

    /// Saves a change to one icon's name, colour or symbol.
    func updateIcon(_ icon: IconDefinition) {
        var icons = project.manifest.icons
        guard let index = icons.firstIndex(where: { $0.id == icon.id }), icons[index] != icon else { return }
        icons[index] = icon
        setIconDefinitions(icons)
    }

    /// Adds an icon with an unused colour and returns it.
    @discardableResult
    func addIcon() -> IconDefinition {
        let icons = project.manifest.icons
        let used = Set(icons.map(\.color))
        let icon = IconDefinition(
            id: IconDefinition.generateID(avoiding: icons),
            name: "New Icon",
            symbol: "star.fill",
            color: IconPalette.colors.first { !used.contains($0) } ?? IconPalette.colors[0]
        )
        setIconDefinitions(icons + [icon])
        return icon
    }

    /// The story-beat icons this project doesn't have (matched by id).
    var missingDefaultIcons: [IconDefinition] {
        let ids = Set(project.manifest.icons.map(\.id))
        return IconDefinition.defaults.filter { !ids.contains($0.id) }
    }

    /// Puts back any missing story-beat icons, after the ones already there.
    func addDefaultIcons() {
        let missing = missingDefaultIcons
        guard !missing.isEmpty else { return }
        setIconDefinitions(project.manifest.icons + missing)
    }

    func deleteIcon(_ id: String) {
        setIconDefinitions(project.manifest.icons.filter { $0.id != id })
    }

    /// Moves an icon one place left (-1) or right (+1) in the list.
    func moveIcon(_ id: String, by offset: Int) {
        var icons = project.manifest.icons
        guard let index = icons.firstIndex(where: { $0.id == id }), icons.indices.contains(index + offset) else { return }
        icons.swapAt(index, index + offset)
        setIconDefinitions(icons)
    }

    /// How many files use an icon.
    func usage(of iconID: String) -> Int {
        project.files.values.filter { $0.icons.contains(iconID) }.count
    }

    /// Editors report their selection's word count here; the last one with a selection wins.
    func setSelectedTextWords(_ count: Int?, from editor: AnyObject, pane: Int) {
        let source = ObjectIdentifier(editor)
        if count == nil, selectedTextSource != source { return }
        selectedTextSource = count == nil ? nil : source
        if selectedTextWords != count { selectedTextWords = count }
        if count != nil, selectedTextPane != pane { selectedTextPane = pane }
    }

    func setIconDefinitions(_ icons: [IconDefinition]) {
        let changed = project.setIconDefinitions(icons)
        writeManifest()
        save(changed, structural: false)
        appearanceRevision += 1
    }

    /// Makes `id` the Working File, or clears it (SPEC.md §8).
    func setWorkingFile(_ id: FileID?) {
        guard project.setWorkingFile(id) else { return }
        writeManifest()
        appearanceRevision += 1
    }

    /// ⌘J: shows the Working File, with the cursor where you left it.
    func jumpToWorkingFile() {
        guard let id = project.manifest.workingFile, project.files[id] != nil else {
            NSSound.beep()
            return
        }
        exitReadModeInActivePane()
        reveal(id)
        if selection != [id] { selection = [id] }
        focusRequest += 1
    }

    /// Bumped to ask the main editor to take keyboard focus.
    private(set) var focusRequest = 0

    func focusEditor() {
        focusRequest += 1
    }

    /// Unfolds the parents of `id` so it shows in the sidebar.
    func reveal(_ id: FileID) {
        var parent = project.tree.parentOf[id]
        while let current = parent {
            expanded.insert(current)
            parent = project.tree.parentOf[current]
        }
    }

    private func writeManifest() {
        do {
            try package.writeManifest(project.manifest)
        } catch {
            AppModel.shared.message = "Couldn’t save the project settings.\n\n\(error.localizedDescription)"
        }
    }

    // MARK: Word count

    /// Per-file (body, outline) word counts, dropped whenever a file is saved or removed.
    @ObservationIgnored private var wordCountCache: [FileID: (body: Int, outline: Int)] = [:]

    /// Word counts for some selected files and the whole project (SPEC.md §10). Reading this
    /// observes `project`, so views update after each autosave.
    func wordCounts(selected: [FileID]) -> WordCounts {
        project.wordCounts(selected: Set(selected)) { file in
            if let cached = wordCountCache[file.id] { return cached }
            let counts = Project.wordCount(of: file)
            wordCountCache[file.id] = counts
            return counts
        }
    }

    // MARK: Copy

    /// One-click copy (SPEC.md §12): the files' draft text, as formatted and plain text.
    func copyDraftText(of ids: [FileID]) {
        commitEditors()
        let text = DraftCopy.attributedString(project.draftText(of: ids))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([text])
    }

    func renameBookmark(_ entry: BookmarkEntry, to name: String) {
        commitEditors()
        guard let file = project.renameBookmark(entry.bookmark.id, in: entry.location.fileID,
                                                inOutline: entry.location.inOutline, to: name) else { return }
        save([file], structural: false)
        contentToken += 1
    }

    func removeBookmark(_ entry: BookmarkEntry) {
        commitEditors()
        guard let file = project.removeBookmark(entry.bookmark.id, in: entry.location.fileID,
                                                inOutline: entry.location.inOutline) else { return }
        snapshotIfDue(file.id)
        save([file], structural: false)
        contentToken += 1
    }

    /// Saves text typed in the editor. Pass nil to leave the body or outline unchanged.
    func updateContent(_ id: FileID, body: [Block]?, outline: [Block]?) {
        guard let file = project.setContent(id, body: body, outline: outline) else { return }
        snapshotIfDue(id)
        save([file], structural: false)
    }

    // MARK: Saving

    /// Files whose last write failed; retried with the next save.
    private var unsaved: Set<FileID> = []
    /// When each file was last snapshotted this session.
    private var lastSnapshot: [FileID: Date] = [:]
    private let snapshotInterval: TimeInterval = 10 * 60

    /// Before the first save of a session, and then at most every 10 minutes, copies the file's
    /// saved version into `snapshots/` (SPEC.md §11).
    private func snapshotIfDue(_ id: FileID) {
        if let last = lastSnapshot[id], Date.now.timeIntervalSince(last) < snapshotInterval { return }
        try? package.snapshot(id)
        lastSnapshot[id] = .now
    }

    private func save(_ files: [PemeriaFile], structural: Bool = true) {
        guard !files.isEmpty else { return }
        if structural { revision += 1 }
        let retries = unsaved.subtracting(files.map(\.id)).compactMap { project.files[$0] }
        unsaved = []
        var failures: [String] = []
        for file in files + retries {
            wordCountCache[file.id] = nil
            do {
                try package.write(file)
            } catch {
                unsaved.insert(file.id)
                failures.append("“\(file.title)”: \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            AppModel.shared.message = "Couldn’t save some changes. They’re still open here; Pemeria will try again on the next change.\n\n"
                + failures.joined(separator: "\n")
        }
    }

    func saveState() {
        try? package.writeState(ProjectState(
            selection: selection,
            expanded: expanded.sorted(),
            positions: Dictionary(uniqueKeysWithValues: positions.map { ($0.key.rawValue, $0.value) }),
            outlinePinned: outlinePinned
        ))
    }
}

/// Which files ⌘F searches.
enum SearchScope: Equatable {
    case project
    /// Files chosen when the scope was set, so jumping to results doesn't change it.
    case files(Set<FileID>)
    /// Files with this icon.
    case icon(String)
}

/// One Replace: the changed files before and after, for Undo.
struct ReplaceRecord {
    let before: [PemeriaFile]
    let after: [PemeriaFile]
    let count: Int
}

struct JumpRequest: Equatable {
    let id: Int
    let location: TextLocation
    /// Set when jumping to a bookmark: the editor finds its tag directly.
    let bookmarkID: String?
}
