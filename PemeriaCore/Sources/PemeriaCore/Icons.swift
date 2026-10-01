import Foundation

extension Project {
    /// A file shows at most this many icons (SPEC.md §4).
    public static let maxIconsPerFile = 3

    /// The definitions of a file's icons, in the file's order. Unknown ids are skipped.
    public func icons(of id: FileID) -> [IconDefinition] {
        guard let file = files[id] else { return [] }
        let definitions = Dictionary(manifest.icons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return file.icons.compactMap { definitions[$0] }.prefix(Self.maxIconsPerFile).map { $0 }
    }

    /// Turns an icon on or off for several files at once: if every file has it, it's removed
    /// from all of them; otherwise it's added to each file that lacks it and has room.
    /// Returns the changed files.
    public mutating func toggleIcon(_ iconID: String, on ids: [FileID]) -> [PemeriaFile] {
        let targets = ids.compactMap { files[$0] }
        guard !targets.isEmpty, manifest.icons.contains(where: { $0.id == iconID }) else { return [] }
        let removing = targets.allSatisfy { $0.icons.contains(iconID) }
        var changed: [PemeriaFile] = []
        for var file in targets {
            if removing {
                file.icons.removeAll { $0 == iconID }
            } else {
                guard !file.icons.contains(iconID), icons(of: file.id).count < Self.maxIconsPerFile else { continue }
                file.icons.append(iconID)
            }
            files[file.id] = file
            changed.append(file)
        }
        return changed
    }

    /// Replaces the project's icon definitions. Files lose any icon whose definition is gone.
    /// Returns the files that changed (the manifest always changes).
    public mutating func setIconDefinitions(_ icons: [IconDefinition]) -> [PemeriaFile] {
        manifest.icons = icons
        let kept = Set(icons.map(\.id))
        var changed: [PemeriaFile] = []
        for var file in files.values where file.icons.contains(where: { !kept.contains($0) }) {
            file.icons.removeAll { !kept.contains($0) }
            files[file.id] = file
            changed.append(file)
        }
        return changed
    }

    /// Makes `id` the Working File (SPEC.md §8), or clears it. Returns false if nothing changed.
    public mutating func setWorkingFile(_ id: FileID?) -> Bool {
        if let id, files[id] == nil { return false }
        guard manifest.workingFile != id else { return false }
        manifest.workingFile = id
        return true
    }
}

extension IconDefinition {
    /// A new icon id, unlike any in `existing`.
    public static func generateID(avoiding existing: [IconDefinition]) -> String {
        let taken = Set(existing.map(\.id))
        while true {
            let candidate = "icon-" + Identifier.generate(length: 5, avoiding: [])
            if !taken.contains(candidate) { return candidate }
        }
    }
}
