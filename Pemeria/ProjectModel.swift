import Foundation
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
    /// Selected files, in book order.
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

    /// Read mode (SPEC.md §12): comments, outlines and bookmarks hidden; not editable.
    var readMode = false {
        willSet { commitEditors() }
    }

    /// A comment or bookmark to move to, set by the right panel and cleared by the editor that shows it.
    var jumpRequest: JumpRequest?
    private var jumpCount = 0

    /// Bumped when a shown file's text is changed from outside the editor (e.g. renaming a
    /// bookmark in the panel), so editors reload it.
    private(set) var contentToken = 0

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
        }
        if project.manifest.workingFile != workingFileBefore {
            do { try package.writeManifest(project.manifest) } catch { failures.append(error.localizedDescription) }
        }
        selection.removeAll { removed.contains($0) }
        expanded.subtract(removed)
        revision += 1
        if !failures.isEmpty {
            AppModel.shared.message = "Some files couldn’t be moved to the trash. They’ll reappear next time the project opens.\n\n"
                + failures.joined(separator: "\n")
        }
    }

    /// Shows the file containing `location` (selecting it if needed) and moves the cursor there.
    func jump(to location: TextLocation, bookmarkID: String? = nil) {
        readMode = false
        if !selection.contains(location.fileID) {
            var parent = project.tree.parentOf[location.fileID]
            while let current = parent {
                expanded.insert(current)
                parent = project.tree.parentOf[current]
            }
            selection = [location.fileID]
        }
        jumpCount += 1
        jumpRequest = JumpRequest(id: jumpCount, location: location, bookmarkID: bookmarkID)
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

struct JumpRequest: Equatable {
    let id: Int
    let location: TextLocation
    /// Set when jumping to a bookmark: the editor finds its tag directly.
    let bookmarkID: String?
}
