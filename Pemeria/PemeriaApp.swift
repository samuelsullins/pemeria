import AppKit
import PemeriaCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pemeriaProject = UTType(exportedAs: "com.samuelsullins.pemeria.project")
}

@main
struct PemeriaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Pemeria", id: "main") {
            RootView(app: .shared)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands { PemeriaCommands(app: .shared) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Double-clicking a project in Finder lands here.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.last { AppModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.project?.close()
    }

    #if DEBUG
    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugSnapshot.scheduleIfRequested()
    }
    #endif
}

#if DEBUG
/// Development aid: launch with `-snapshotEvery <seconds>` and the app draws its own window
/// into `debug-snapshot.png` inside the open project on that interval (the one place both the
/// sandboxed app and outside tools can reach). Needs no screen-recording permission.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        let interval = UserDefaults.standard.double(forKey: "snapshotEvery")
        guard interval > 0 else { return }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { capture() }
        }
    }

    static func capture() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let project = AppModel.shared.project else { return }
        let url = project.package.url.appending(path: "debug-snapshot.png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

struct PemeriaCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Draft") { app.project?.newFile(kind: .draft) }
                .keyboardShortcut("n")
                .disabled(app.project == nil)
            Button("New Note") { app.project?.newFile(kind: .note) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(app.project == nil)
            Divider()
            Button("New Project…") { app.showNewProjectPanel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Project…") { app.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.recentProjects, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { app.open(url) }
                }
                Divider()
                Button("Clear Menu") { app.clearRecentProjects() }
                    .disabled(app.recentProjects.isEmpty)
            }
        }
    }
}
