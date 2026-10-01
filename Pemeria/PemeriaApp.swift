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

    init() {
        EditorStyle.registerDefaults()
    }

    var body: some Scene {
        Window("Pemeria", id: "main") {
            RootView(app: .shared)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands { PemeriaCommands(app: .shared) }

        Settings {
            PreferencesView()
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.apply()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Theme.apply() }
        }
    }
}

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

        CommandGroup(after: .sidebar) {
            Button(app.project?.outlinePinned == true ? "Unpin Outline" : "Pin Outline") {
                if let project = app.project { project.outlinePinned.toggle() }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(app.project == nil)
        }

        CommandMenu("Format") {
            Button("Italic") { NSApp.sendAction(#selector(EditorTextView.toggleItalic(_:)), to: nil, from: nil) }
                .keyboardShortcut("i")
            Button("Bold") { NSApp.sendAction(#selector(EditorTextView.toggleBold(_:)), to: nil, from: nil) }
                .keyboardShortcut("b")
        }
    }
}
