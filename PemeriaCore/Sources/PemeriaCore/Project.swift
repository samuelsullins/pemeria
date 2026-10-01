import Foundation

/// A project in memory, and the structural edits the sidebar makes to it.
///
/// Each edit returns the files it changed so the caller can write exactly those.
public struct Project: Sendable {
    public var manifest: ProjectManifest
    public private(set) var files: [FileID: PemeriaFile]
    public private(set) var tree: ProjectTree

    public init(manifest: ProjectManifest, files: [FileID: PemeriaFile]) {
        self.manifest = manifest
        self.files = files
        self.tree = ProjectTree(files: Array(files.values))
    }

    public init(_ loaded: ProjectPackage.Loaded) {
        self.init(manifest: loaded.manifest, files: loaded.files)
    }

    /// The children of `parent`, or the top-level files when `parent` is nil.
    public func children(of parent: FileID?) -> [FileID] {
        parent.map(tree.children(of:)) ?? tree.roots
    }

    /// Every file nested anywhere under `id`, in book order.
    public func descendants(of id: FileID) -> [FileID] {
        tree.children(of: id).flatMap { [$0] + descendants(of: $0) }
    }

    /// `ids` in book order, without any file that's already nested under another one in the list.
    public func topmost(_ ids: [FileID]) -> [FileID] {
        let set = Set(ids)
        return tree.bookOrder.filter { id in
            guard set.contains(id) else { return false }
            var parent = tree.parentOf[id]
            while let current = parent {
                if set.contains(current) { return false }
                parent = tree.parentOf[current]
            }
            return true
        }
    }

    // MARK: Edits

    /// Adds a new file just after `sibling` (same parent), or at the end of the top level.
    public mutating func createFile(kind: FileKind, title: String = "Untitled", after sibling: FileID? = nil) -> PemeriaFile {
        let parent = sibling.flatMap { tree.parentOf[$0] }
        let siblings = children(of: parent)
        let index = sibling.flatMap { siblings.firstIndex(of: $0) }.map { $0 + 1 } ?? siblings.count
        let file = PemeriaFile(
            id: FileID.generate(avoiding: files.keys),
            title: title,
            parent: parent,
            order: "",
            kind: kind,
            outline: kind == .draft ? [] : nil
        )
        files[file.id] = file
        let changed = place([file.id], in: parent, at: index)
        return changed.first { $0.id == file.id }!
    }

    /// Renames a file. Returns nil if nothing changed (same title, empty title, or unknown file).
    public mutating func rename(_ id: FileID, to title: String) -> PemeriaFile? {
        let title = title.singleLine
        guard var file = files[id], !title.trimmingCharacters(in: .whitespaces).isEmpty, file.title != title else { return nil }
        file.title = title
        files[id] = file
        return file
    }

    /// Switches files between draft and note. A draft's outline is kept (hidden) while it's a note.
    public mutating func setKind(_ ids: [FileID], to kind: FileKind) -> [PemeriaFile] {
        ids.compactMap { id in
            guard var file = files[id], file.kind != kind else { return nil }
            file.kind = kind
            if kind == .draft, file.outline == nil { file.outline = [] }
            files[id] = file
            return file
        }
    }

    /// Whether `ids` can be moved under `parent` (nil = top level).
    /// A file can't move into itself or anywhere nested inside itself.
    public func canMove(_ ids: [FileID], into parent: FileID?) -> Bool {
        guard !ids.isEmpty, ids.allSatisfy({ files[$0] != nil }) else { return false }
        guard let parent else { return true }
        guard files[parent] != nil else { return false }
        var current: FileID? = parent
        while let node = current {
            if ids.contains(node) { return false }
            current = tree.parentOf[node]
        }
        return true
    }

    /// Moves files (and everything nested in them) to `index` among `parent`'s children,
    /// where `index` counts the children as they are now. Returns the files that changed,
    /// or nil if the move isn't allowed.
    public mutating func move(_ ids: [FileID], into parent: FileID?, at index: Int) -> [PemeriaFile]? {
        let moving = topmost(ids)
        guard canMove(moving, into: parent) else { return nil }
        return place(moving, in: parent, at: index)
    }

    /// Removes files and everything nested in them. Returns the removed ids, parents first.
    public mutating func remove(_ ids: [FileID]) -> [FileID] {
        let removed = topmost(ids).flatMap { [$0] + descendants(of: $0) }
        for id in removed { files[id] = nil }
        if let working = manifest.workingFile, removed.contains(working) { manifest.workingFile = nil }
        tree = ProjectTree(files: Array(files.values))
        return removed
    }

    /// Puts `ids` (in that order) at `index` among `parent`'s current children and gives them
    /// order keys. Only the moved files change, unless the neighbours' keys leave no room,
    /// in which case the whole sibling list is renumbered.
    private mutating func place(_ ids: [FileID], in parent: FileID?, at index: Int) -> [PemeriaFile] {
        let moving = Set(ids)
        let siblings = children(of: parent)
        let index = min(max(index, 0), siblings.count)
        let before = siblings[..<index].last { !moving.contains($0) }
        let after = siblings[index...].first { !moving.contains($0) }

        var assignments: [(FileID, String)]
        if let keys = OrderKey.sequence(count: ids.count, between: before.map { files[$0]!.order }, and: after.map { files[$0]!.order }) {
            assignments = Array(zip(ids, keys))
        } else {
            var order = siblings.filter { !moving.contains($0) }
            let insertAt = siblings[..<index].filter { !moving.contains($0) }.count
            order.insert(contentsOf: ids, at: insertAt)
            assignments = Array(zip(order, OrderKey.sequence(count: order.count)!))
        }

        var changed: [PemeriaFile] = []
        for (id, key) in assignments {
            guard var file = files[id] else { continue }
            let newParent = moving.contains(id) ? parent : file.parent
            guard file.order != key || file.parent != newParent else { continue }
            file.order = key
            file.parent = newParent
            files[id] = file
            changed.append(file)
        }
        tree = ProjectTree(files: Array(files.values))
        return changed
    }
}

/// Window state for a project, kept in `state.json`. Safe to lose.
public struct ProjectState: Codable, Hashable, Sendable {
    public var selection: [FileID]
    public var expanded: [FileID]

    public init(selection: [FileID] = [], expanded: [FileID] = []) {
        self.selection = selection
        self.expanded = expanded
    }
}
