import Foundation
import Observation
import PemeriaCore
import SwiftUI

/// One open project, read straight from its package (usually in iCloud Drive) and re-read
/// whenever the package changes. Never writes to the package.
@Observable
final class ProjectReader {
    enum Status: Equatable {
        case loading
        /// iCloud is still bringing the project to this device.
        case downloading(remaining: Int)
        case ready
        case failed(String)
    }

    let id: UUID
    let name: String
    /// The last version read in full. Kept on screen while a newer one downloads.
    private(set) var project: Project?
    private(set) var status: Status = .loading
    /// Each file's word count (body only), and the project's totals.
    private(set) var bodyWords: [FileID: Int] = [:]
    private(set) var totals = WordCounts()

    /// Which files are unfolded in the file list. Starts out matching the Mac's sidebar.
    private(set) var expanded: Set<FileID> = []

    private var url: URL?
    private var accessing = false
    private var presenter: PackagePresenter?
    private var loadTask: Task<Void, Never>?
    private var reloadAgain = false
    private var scheduled: Task<Void, Never>?
    private let onUpdate: (_ name: String?, _ bookmark: Data?) -> Void

    init(recent: RecentProject, onUpdate: @escaping (_ name: String?, _ bookmark: Data?) -> Void) {
        id = recent.id
        name = recent.name
        self.onUpdate = onUpdate
        if let saved = UserDefaults.standard.array(forKey: expandedKey) as? [String] {
            expanded = Set(saved.compactMap(FileID.init))
            hasExpansion = true
        }

        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, bookmarkDataIsStale: &stale) else {
            status = .failed("This project may have been moved or deleted. Open it again from Files.")
            return
        }
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData() {
            Task { onUpdate(nil, fresh) }
        }

        let presenter = PackagePresenter(url: url) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.changedOnDisk() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        self.presenter = presenter
        reload()
    }

    func close() {
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        scheduled?.cancel()
        loadTask?.cancel()
        if accessing { url?.stopAccessingSecurityScopedResource() }
        accessing = false
        url = nil
    }

    // MARK: Reading

    /// Reads the project again. If a read is already running, another follows it.
    func reload() {
        guard let url else { return }
        if loadTask != nil {
            reloadAgain = true
            return
        }
        loadTask = Task {
            let outcome = await Task.detached { Self.read(url) }.value
            apply(outcome)
            loadTask = nil
            if reloadAgain {
                reloadAgain = false
                reload()
            }
        }
    }

    /// Reloads and waits for it to finish (pull to refresh).
    func refresh() async {
        reload()
        while let task = loadTask { await task.value }
    }

    private func changedOnDisk() {
        // Saves touch several files at once; read once they've settled.
        schedule(after: .milliseconds(400))
    }

    private func schedule(after delay: Duration) {
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private var hasExpansion = false

    private func apply(_ outcome: ReadOutcome) {
        switch outcome {
        case .loaded(let project, let state, let words):
            if self.project?.files != project.files || self.project?.manifest != project.manifest {
                self.project = project
                bodyWords = words
                totals = project.wordCounts(selected: []) { file in (words[file.id] ?? 0, Project.wordCount(of: file).outline) }
            }
            if !hasExpansion {
                expanded = Set(state?.expanded ?? [])
                hasExpansion = true
            }
            status = .ready
            onUpdate(project.manifest.name, nil)
        case .pending(let remaining):
            if project == nil { status = .downloading(remaining: remaining) }
            // iCloud usually tells the presenter when files land, but don't rely on it.
            schedule(after: .seconds(2))
        case .failed(let message):
            // Keep showing the last good version; a half-synced save can fail to read.
            if project == nil { status = .failed(message) }
        }
    }

    // MARK: Folding

    func isExpanded(_ id: FileID) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(id) },
            set: { open in
                if open { self.expanded.insert(id) } else { self.expanded.remove(id) }
                UserDefaults.standard.set(self.expanded.map(\.rawValue), forKey: self.expandedKey)
            }
        )
    }

    private var expandedKey: String { "expanded.\(id.uuidString)" }

    /// Words in a file and everything nested in it.
    func words(inTree id: FileID) -> Int {
        guard let project else { return 0 }
        return ([id] + project.descendants(of: id)).reduce(0) { $0 + (bodyWords[$1] ?? 0) }
    }
}

// MARK: - Reading from disk

nonisolated enum ReadOutcome: Sendable {
    case loaded(Project, ProjectState?, [FileID: Int])
    /// This many items are still downloading from iCloud.
    case pending(Int)
    case failed(String)
}

extension ProjectReader {
    /// Reads the package without changing it. Runs off the main thread.
    nonisolated static func read(_ url: URL) -> ReadOutcome {
        let missing = requestDownloads(in: url)
        if missing > 0 { return .pending(missing) }

        var outcome = ReadOutcome.failed("The project couldn’t be read.")
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do {
                let package = ProjectPackage(url: url)
                let project = Project(try package.load(repairing: false))
                let words = project.files.mapValues { Project.wordCount(of: $0).body }
                outcome = .loaded(project, package.loadState(), words)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
        if let coordinationError { return .failed(coordinationError.localizedDescription) }
        return outcome
    }

    /// Asks iCloud for anything in the package that isn't on this device yet, and returns how
    /// many items are still missing. Outside iCloud everything is always here, so this is 0.
    nonisolated static func requestDownloads(in url: URL) -> Int {
        let fileManager = FileManager.default
        func fetch(_ item: URL) {
            try? fileManager.startDownloadingUbiquitousItem(at: item)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            fetch(url)
            return 1
        }

        var missing = 0
        let folders = [url, url.appending(path: "files", directoryHint: .isDirectory)]
        for folder in folders {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]
            ) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                // A hidden ".name.icloud" can stand in for a file that isn't downloaded yet.
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    guard real == "project.json" || real == "files" || real.hasSuffix(".md") else { continue }
                    fetch(folder.appending(path: real))
                    missing += 1
                    continue
                }
                guard name == "project.json" || entry.pathExtension == "md" else { continue }
                switch try? entry.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus {
                case .notDownloaded?:
                    fetch(entry)
                    missing += 1
                case .downloaded?:
                    // An older copy is here and readable; fetch the latest too.
                    fetch(entry)
                default:
                    break
                }
            }
        }
        return missing
    }
}

/// Hears about changes made inside the package: iCloud downloading the Mac's latest saves.
nonisolated final class PackagePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let changed: @Sendable () -> Void

    init(url: URL, changed: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        self.changed = changed
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func presentedItemDidChange() { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        completionHandler(nil)
        changed()
    }
}
