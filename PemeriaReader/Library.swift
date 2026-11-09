import Foundation
import Observation
import PemeriaCore
import UniformTypeIdentifiers

extension UTType {
    static let pemeriaProject = UTType(exportedAs: "com.samuelsullins.pemeria.project")
}

/// A project opened on this device before. The bookmark keeps permission to read it across
/// launches, so it reopens without going back through Files.
struct RecentProject: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var bookmark: Data
    var lastOpened: Date
}

/// Where the app is: a project's file list, or a file being read. Saved, so the app reopens
/// where you left off.
enum Route: Hashable, Codable {
    case project(UUID)
    case file(UUID, FileID)

    var projectID: UUID {
        switch self {
        case .project(let id), .file(let id, _): id
        }
    }
}

/// The projects this device knows about, and the navigation path through them.
@Observable
final class Library {
    private(set) var recents: [RecentProject] {
        didSet { Self.save(recents, key: Keys.recents) }
    }

    var path: [Route] {
        didSet { pathChanged(from: oldValue) }
    }

    /// Shown as an alert, then cleared.
    var error: String?

    /// One reader per project on the navigation path; closed when you leave the project.
    private var readers: [UUID: ProjectReader] = [:]

    private enum Keys {
        static let recents = "recentProjects"
        static let path = "navigationPath"
    }

    init() {
        let recents = Self.load([RecentProject].self, key: Keys.recents) ?? []
        self.recents = recents
        let known = Set(recents.map(\.id))
        path = (Self.load([Route].self, key: Keys.path) ?? []).filter { known.contains($0.projectID) }
        syncReaders()
    }

    var sortedRecents: [RecentProject] {
        recents.sorted { $0.lastOpened > $1.lastOpened }
    }

    func reader(for id: UUID) -> ProjectReader? {
        readers[id]
    }

    /// Adds a project picked in Files (or handed over by Files) and shows it. A project that's
    /// already in the list is reopened rather than added twice.
    func add(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == ProjectPackage.fileExtension
                || FileManager.default.fileExists(atPath: url.appending(path: "project.json").path) else {
            error = "“\(url.lastPathComponent)” isn’t a Pemeria project."
            return
        }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData()
        } catch {
            self.error = "Couldn’t open “\(name)”: \(error.localizedDescription)"
            return
        }

        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let id: UUID
        if let index = recents.firstIndex(where: { Self.resolvedPath(of: $0) == target }) {
            id = recents[index].id
            recents[index].bookmark = bookmark
        } else {
            id = UUID()
            recents.append(RecentProject(id: id, name: name, bookmark: bookmark, lastOpened: .now))
        }
        path = [.project(id)]
    }

    /// Forgets a project. The project itself is untouched.
    func remove(_ id: UUID) {
        path.removeAll { $0.projectID == id }
        recents.removeAll { $0.id == id }
    }

    /// Re-reads every open project, e.g. when the app comes back to the front.
    func refreshOpenProjects() {
        for reader in readers.values { reader.reload() }
    }

    private func pathChanged(from old: [Route]) {
        Self.save(path, key: Keys.path)
        if let id = path.first?.projectID, id != old.first?.projectID,
           let index = recents.firstIndex(where: { $0.id == id }) {
            recents[index].lastOpened = .now
        }
        syncReaders()
    }

    /// Opens a reader for each project on the path and closes the rest. Done here rather than
    /// when a screen first draws, so no state changes while SwiftUI is drawing.
    private func syncReaders() {
        let open = Set(path.map(\.projectID))
        for id in readers.keys where !open.contains(id) {
            readers[id]?.close()
            readers[id] = nil
        }
        for id in open where readers[id] == nil {
            guard let recent = recents.first(where: { $0.id == id }) else { continue }
            readers[id] = ProjectReader(recent: recent) { [weak self] name, bookmark in
                self?.update(id, name: name, bookmark: bookmark)
            }
        }
    }

    private func update(_ id: UUID, name: String?, bookmark: Data?) {
        guard let index = recents.firstIndex(where: { $0.id == id }) else { return }
        if let name, recents[index].name != name { recents[index].name = name }
        if let bookmark { recents[index].bookmark = bookmark }
    }

    private static func resolvedPath(of recent: RecentProject) -> String? {
        var stale = false
        return (try? URL(resolvingBookmarkData: recent.bookmark, bookmarkDataIsStale: &stale))?
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
