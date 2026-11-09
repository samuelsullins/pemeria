import Foundation

/// Reads and writes a `.pemeria` package on disk. See SPEC.md §2 and §11.
///
/// ```
/// My Novel.pemeria/
///   project.json
///   files/<id>.md
///   snapshots/<id>/<timestamp>.md
///   trash/<id> <timestamp>.md
/// ```
///
/// Every write goes to a temporary file first and is then swapped in, so a crash
/// mid-save leaves the previous version intact.
public struct ProjectPackage: Sendable {
    public static let fileExtension = "pemeria"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    var manifestURL: URL { url.appending(path: "project.json") }
    var filesURL: URL { url.appending(path: "files", directoryHint: .isDirectory) }
    var snapshotsURL: URL { url.appending(path: "snapshots", directoryHint: .isDirectory) }
    var trashURL: URL { url.appending(path: "trash", directoryHint: .isDirectory) }

    func fileURL(for id: FileID) -> URL {
        filesURL.appending(path: "\(id.rawValue).md")
    }

    // MARK: Creating and loading

    /// Creates a new, empty project. Fails if something already exists at `url`.
    @discardableResult
    public static func create(at url: URL, name: String) throws -> ProjectPackage {
        let package = ProjectPackage(url: url)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
        }
        try fileManager.createDirectory(at: package.filesURL, withIntermediateDirectories: true)
        try package.writeManifest(ProjectManifest(name: name))
        return package
    }

    public struct Loaded: Sendable {
        public var manifest: ProjectManifest
        public var files: [FileID: PemeriaFile]
        /// Things that were wrong and how they were handled. Nothing here means data was lost.
        public var problems: [String]

        public var tree: ProjectTree { ProjectTree(files: Array(files.values)) }
    }

    /// Loads the whole project. Repairs it as needed: a duplicate or invalid id gets a fresh
    /// id and its file is renamed to match (the new file is written before the old one is removed).
    ///
    /// With `repairing` false nothing is written: the same repairs are made in memory only, for
    /// read-only viewers (the iPhone app) that must never change a project the Mac owns.
    public func load(repairing: Bool = true) throws -> Loaded {
        let fileManager = FileManager.default
        var problems: [String] = []

        let manifest: ProjectManifest
        if fileManager.fileExists(atPath: manifestURL.path) {
            manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        } else {
            let name = url.deletingPathExtension().lastPathComponent
            manifest = ProjectManifest(name: name)
            if repairing {
                try writeManifest(manifest)
                problems.append("project.json was missing; created a new one.")
            } else {
                problems.append("project.json is missing.")
            }
        }

        if repairing {
            try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)
        } else if !fileManager.fileExists(atPath: filesURL.path) {
            return Loaded(manifest: manifest, files: [:], problems: problems + ["The files folder is missing."])
        }
        let entries = try fileManager
            .contentsOfDirectory(at: filesURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var files: [FileID: PemeriaFile] = [:]
        var misnamed: [(file: PemeriaFile, source: URL)] = []
        for entry in entries {
            let data = try Data(contentsOf: entry)
            guard let text = String(data: data, encoding: .utf8) else {
                problems.append("\(entry.lastPathComponent) isn't valid UTF-8 text; left untouched and not loaded.")
                continue
            }
            let stem = entry.deletingPathExtension().lastPathComponent
            let fallback = FileID(stem) ?? FileID.generate(avoiding: files.keys)
            let file = FileCodec.decode(text, fallbackID: fallback)
            if file.id.rawValue == stem, files[file.id] == nil {
                files[file.id] = file
            } else {
                misnamed.append((file, entry))
            }
        }

        // Files whose name doesn't match their id, or whose id is already taken.
        for (original, source) in misnamed {
            var file = original
            if files[file.id] != nil || fileManager.fileExists(atPath: fileURL(for: file.id).path) {
                file.id = FileID.generate(avoiding: Array(files.keys) + misnamed.map(\.file.id))
            }
            if repairing {
                try write(file)
                try fileManager.removeItem(at: source)
                problems.append("\(source.lastPathComponent) was renamed to \(file.id.rawValue).md to match its id.")
            } else {
                problems.append("\(source.lastPathComponent) doesn't match its id; shown as \(file.id.rawValue).")
            }
            files[file.id] = file
        }

        return Loaded(manifest: manifest, files: files, problems: problems)
    }

    // MARK: Writing

    public func writeManifest(_ manifest: ProjectManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    var stateURL: URL { url.appending(path: "state.json") }

    /// The saved window state, or nil if there is none or it can't be read.
    public func loadState() -> ProjectState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(ProjectState.self, from: data)
    }

    public func writeState(_ state: ProjectState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    /// Writes one file, unless the file on disk already has exactly this content.
    public func write(_ file: PemeriaFile) throws {
        let data = Data(FileCodec.encode(file).utf8)
        let destination = fileURL(for: file.id)
        if let existing = try? Data(contentsOf: destination), existing == data { return }
        try FileManager.default.createDirectory(at: filesURL, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// Moves a file into the project's trash. It can be restored until the trash is emptied.
    public func moveToTrash(_ id: FileID, date: Date = .now) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: trashURL, withIntermediateDirectories: true)
        let destination = trashURL.appending(path: "\(id.rawValue) \(Self.timestamp(date)).md")
        try fileManager.moveItem(at: fileURL(for: id), to: destination)
    }

    /// Copies a file's current saved text into `snapshots/<id>/`.
    public func snapshot(_ id: FileID, date: Date = .now) throws {
        let fileManager = FileManager.default
        let folder = snapshotsURL.appending(path: id.rawValue, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "\(Self.timestamp(date)).md")
        try Data(contentsOf: fileURL(for: id)).write(to: destination, options: .atomic)
    }

    /// Saved snapshots of a file, oldest first.
    public func snapshots(of id: FileID) throws -> [URL] {
        let folder = snapshotsURL.appending(path: id.rawValue, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }
}
