import AppKit
import Observation
import PemeriaCore

/// App-wide state: which project is open, recent projects, and errors to show.
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var project: ProjectModel?
    private(set) var recentProjects: [URL] = []
    /// Shown as an alert, then cleared.
    var message: String?

    private init() {
        recentProjects = RecentProjects.load()
        if let last = recentProjects.first {
            open(last, quietly: true)
        }
    }

    /// Opens a project. With `quietly`, a project that can't be opened is skipped without an alert
    /// (used when reopening the last project on launch).
    func open(_ url: URL, quietly: Bool = false) {
        if project?.package.url.standardizedFileURL == url.standardizedFileURL { return }
        do {
            let model = try ProjectModel(url: url)
            project?.close()
            project = model
            RecentProjects.add(url)
            recentProjects = RecentProjects.load()
            if !model.problems.isEmpty {
                message = "Pemeria tidied up a few things while opening this project. Nothing was lost.\n\n"
                    + model.problems.joined(separator: "\n")
            }
        } catch {
            if !quietly {
                message = "Couldn’t open “\(url.deletingPathExtension().lastPathComponent)”.\n\n\(error.localizedDescription)"
            }
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pemeriaProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Pemeria project"
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func showNewProjectPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pemeriaProject]
        panel.nameFieldStringValue = "Untitled Novel"
        panel.message = "Name your new project"
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = url.deletingPathExtension().lastPathComponent
            let package = try ProjectPackage.create(at: url, name: name)
            var project = Project(manifest: try package.load().manifest, files: [:])
            try package.write(project.createFile(kind: .draft, title: "Chapter 1"))
            open(url)
        } catch CocoaError.fileWriteFileExists {
            message = "There’s already something called “\(url.lastPathComponent)” there. Pemeria won’t replace it; choose another name."
        } catch {
            message = "Couldn’t create the project.\n\n\(error.localizedDescription)"
        }
    }

    func clearRecentProjects() {
        RecentProjects.clear()
        recentProjects = []
    }
}

/// Recently opened projects, stored as security-scoped bookmarks so the sandboxed app can
/// reopen them after a relaunch, even if they've been moved or renamed.
enum RecentProjects {
    private static let key = "recentProjects"
    private static let limit = 10

    static func load() -> [URL] {
        bookmarks().compactMap { resolve($0) }
    }

    static func add(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }
        let others = bookmarks().filter { resolve($0)?.standardizedFileURL != url.standardizedFileURL }
        UserDefaults.standard.set(Array(([bookmark] + others).prefix(limit)), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func bookmarks() -> [Data] {
        UserDefaults.standard.array(forKey: key) as? [Data] ?? []
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
    }
}
