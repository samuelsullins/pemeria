import Foundation
import Observation
import PemeriaCore

/// One open project: the in-memory `Project`, what's selected and folded, and saving.
/// Every edit is written to disk straight away.
@Observable
final class ProjectModel {
    let package: ProjectPackage
    private(set) var project: Project
    /// Bumped whenever the sidebar's contents change (names, kinds, structure).
    private(set) var revision = 0
    /// Selected files, in book order.
    var selection: [FileID] = [] {
        didSet { if selection != oldValue { saveState() } }
    }
    /// Parents whose children are showing.
    var expanded: Set<FileID> = [] {
        didSet { if expanded != oldValue { saveState() } }
    }
    /// Set to start renaming a file in the sidebar (e.g. right after creating it).
    var renameRequest: FileID?
    /// Repairs made while loading, for the user to see once.
    let problems: [String]

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
        }
    }

    func close() {
        saveState()
        if isAccessingSecurityScope { package.url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Edits

    /// Creates a file after `sibling` (default: the last selected file), selects it, and starts renaming it.
    func newFile(kind: FileKind, after sibling: FileID? = nil) {
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
        save(project.setKind(ids, to: kind))
    }

    /// Returns false if the move isn't allowed.
    @discardableResult
    func move(_ ids: [FileID], into parent: FileID?, at index: Int) -> Bool {
        guard let changed = project.move(ids, into: parent, at: index) else { return false }
        save(changed)
        if let parent { expanded.insert(parent) }
        return true
    }

    /// Moves files, and everything nested in them, into the project's trash folder.
    func trash(_ ids: [FileID]) {
        let workingFileBefore = project.manifest.workingFile
        let removed = project.remove(ids)
        var failures: [String] = []
        for id in removed {
            do { try package.moveToTrash(id) } catch { failures.append(error.localizedDescription) }
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

    // MARK: Saving

    /// Files whose last write failed; retried with the next save.
    private var unsaved: Set<FileID> = []

    private func save(_ files: [PemeriaFile]) {
        guard !files.isEmpty else { return }
        revision += 1
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

    private func saveState() {
        try? package.writeState(ProjectState(selection: selection, expanded: expanded.sorted()))
    }
}
