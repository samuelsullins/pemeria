import Foundation

extension Project {
    /// Every file has this many label slots (SPEC.md §4).
    public static let maxIconsPerFile = 3

    /// A file's label slots, always `maxIconsPerFile` of them: each slot's label, or nil when
    /// it's empty (or names a label that no longer exists).
    public func iconSlots(of id: FileID) -> [IconDefinition?] {
        let stored = files[id]?.icons ?? []
        let definitions = Dictionary(manifest.icons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (0..<Self.maxIconsPerFile).map { slot in
            slot < stored.count ? definitions[stored[slot]] : nil
        }
    }

    /// The labels in a file's slots, in slot order, leaving out empty slots.
    public func icons(of id: FileID) -> [IconDefinition] {
        iconSlots(of: id).compactMap { $0 }
    }

    /// The first empty slot of a file, if it has one.
    public func freeIconSlot(of id: FileID) -> Int? {
        iconSlots(of: id).firstIndex { $0 == nil }
    }

    /// Puts a label in one of a file's slots, or empties the slot with nil. A label already in
    /// another of the file's slots moves here. Returns the file if it changed.
    public mutating func setIcon(_ iconID: String?, slot: Int, of id: FileID) -> PemeriaFile? {
        guard var file = files[id], (0..<Self.maxIconsPerFile).contains(slot) else { return nil }
        if let iconID, !manifest.icons.contains(where: { $0.id == iconID }) { return nil }
        let before = file
        while file.icons.count <= slot { file.icons.append("") }
        if let iconID {
            for index in file.icons.indices where file.icons[index] == iconID { file.icons[index] = "" }
        }
        file.icons[slot] = iconID ?? ""
        file = file.canonicalized()
        guard file != before.canonicalized() else { return nil }
        files[id] = file
        return file
    }

    /// Turns an icon on or off for several files at once: if every file has it, it's taken out
    /// of its slot in each; otherwise it goes into the first empty slot of each file that lacks
    /// it and has one free. Returns the changed files.
    public mutating func toggleIcon(_ iconID: String, on ids: [FileID]) -> [PemeriaFile] {
        let targets = ids.compactMap { files[$0] }
        guard !targets.isEmpty, manifest.icons.contains(where: { $0.id == iconID }) else { return [] }
        let removing = targets.allSatisfy { iconSlots(of: $0.id).contains { $0?.id == iconID } }
        var changed: [PemeriaFile] = []
        for file in targets {
            let slots = iconSlots(of: file.id)
            let slot: Int?
            if removing {
                slot = slots.firstIndex { $0?.id == iconID }
            } else {
                slot = slots.contains { $0?.id == iconID } ? nil : freeIconSlot(of: file.id)
            }
            guard let slot, let updated = setIcon(removing ? nil : iconID, slot: slot, of: file.id) else { continue }
            changed.append(updated)
        }
        return changed
    }

    /// Replaces the project's icon definitions. Files lose any icon whose definition is gone;
    /// its slot is left empty. Returns the files that changed (the manifest always changes).
    public mutating func setIconDefinitions(_ icons: [IconDefinition]) -> [PemeriaFile] {
        manifest.icons = icons
        let kept = Set(icons.map(\.id))
        var changed: [PemeriaFile] = []
        for var file in files.values where file.icons.contains(where: { !$0.isEmpty && !kept.contains($0) }) {
            file.icons = file.icons.map { kept.contains($0) ? $0 : "" }
            file = file.canonicalized()
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
