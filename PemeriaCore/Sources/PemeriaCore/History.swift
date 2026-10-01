import Foundation

/// A saved copy of a file in `snapshots/` (SPEC.md §11).
public struct SavedVersion: Hashable, Sendable, Identifiable {
    public let url: URL
    public let date: Date
    public var id: URL { url }
}

/// A file in the project's `trash/`, read back in.
public struct TrashedFile: Hashable, Sendable, Identifiable {
    public let url: URL
    /// When it was moved to the trash.
    public let date: Date
    public let file: PemeriaFile
    public var id: URL { url }
}

extension ProjectPackage {
    static func date(fromTimestamp text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.date(from: text)
    }

    /// A file's snapshots, newest first.
    public func versions(of id: FileID) -> [SavedVersion] {
        let urls = (try? snapshots(of: id)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "md",
                  let date = Self.date(fromTimestamp: url.deletingPathExtension().lastPathComponent) else { return nil }
            return SavedVersion(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Reads a snapshot. Its id is taken to be `id`, whatever the copy says.
    public func read(_ version: SavedVersion, of id: FileID) throws -> PemeriaFile {
        var file = FileCodec.decode(try String(contentsOf: version.url, encoding: .utf8), fallbackID: id)
        file.id = id
        return file
    }

    /// Everything in the trash, most recently trashed first. Unreadable entries are skipped.
    public func trashedFiles() -> [TrashedFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url -> TrashedFile? in
            guard url.pathExtension == "md" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = FileID(parts[0]), let date = Self.date(fromTimestamp: parts[1]),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return TrashedFile(url: url, date: date, file: FileCodec.decode(text, fallbackID: id))
        }
        .sorted { $0.date > $1.date }
    }

    /// Takes a file out of the trash: writes `file` (as restored into the project, possibly
    /// with a new id or parent) to `files/`, then removes the trash copy.
    public func restore(_ trashed: TrashedFile, as file: PemeriaFile) throws {
        try write(file)
        try FileManager.default.removeItem(at: trashed.url)
    }

    /// Empty Trash: permanently deletes everything in the trash, and the snapshots of
    /// files that are no longer in the project.
    public func emptyTrash(keepingSnapshotsOf liveIDs: Set<FileID>) throws {
        let fileManager = FileManager.default
        for url in (try? fileManager.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil)) ?? [] {
            try fileManager.removeItem(at: url)
        }
        for folder in (try? fileManager.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = FileID(folder.lastPathComponent), !liveIDs.contains(id) else { continue }
            try fileManager.removeItem(at: folder)
        }
    }
}
