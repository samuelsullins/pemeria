/// The sidebar hierarchy, rebuilt from each file's own `parent` and `order`.
///
/// Damaged structure (hand edits, a future sync conflict) never hides a file:
/// a missing parent or a parent loop puts the file at the top level instead.
public struct ProjectTree: Hashable, Sendable {
    public private(set) var roots: [FileID] = []
    public private(set) var childrenByParent: [FileID: [FileID]] = [:]
    /// Effective parents after repairs, so may differ from a file's stored `parent`.
    public private(set) var parentOf: [FileID: FileID] = [:]

    public init(files: [PemeriaFile]) {
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for file in byID.values {
            if let parent = file.parent, parent != file.id, byID[parent] != nil {
                parentOf[file.id] = parent
            }
        }

        // Break parent loops by promoting the lowest id in each loop to the top level.
        for id in byID.keys.sorted() {
            var seen: [FileID] = []
            var current: FileID? = id
            while let node = current, parentOf[node] != nil {
                if let loopStart = seen.firstIndex(of: node) {
                    let loop = seen[loopStart...]
                    parentOf[loop.min()!] = nil
                    break
                }
                seen.append(node)
                current = parentOf[node]
            }
        }

        let sortedIDs = byID.values
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .map(\.id)
        for id in sortedIDs {
            if let parent = parentOf[id] {
                childrenByParent[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }
    }

    public func children(of id: FileID) -> [FileID] {
        childrenByParent[id] ?? []
    }

    /// Every file in book order: each parent followed by its children, depth first.
    public var bookOrder: [FileID] {
        var result: [FileID] = []
        func visit(_ id: FileID) {
            result.append(id)
            children(of: id).forEach(visit)
        }
        roots.forEach(visit)
        return result
    }

    /// How deeply `id` is nested (0 = top level).
    public func depth(of id: FileID) -> Int {
        var depth = 0
        var current = id
        while let parent = parentOf[current] {
            depth += 1
            current = parent
        }
        return depth
    }
}
