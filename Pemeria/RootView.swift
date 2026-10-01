import PemeriaCore
import SwiftUI

struct RootView: View {
    let app: AppModel

    var body: some View {
        Group {
            if let project = app.project {
                ProjectView(model: project)
                    .id(ObjectIdentifier(project))
            } else {
                WelcomeView(app: app)
            }
        }
        .alert(
            "Pemeria",
            isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } }),
            actions: { Button("OK") {} },
            message: { Text(app.message ?? "") }
        )
    }
}

struct WelcomeView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Pemeria")
                .font(.system(size: 34, weight: .semibold, design: .serif))
            HStack(spacing: 12) {
                Button("New Project…") { app.showNewProjectPanel() }
                    .keyboardShortcut(.defaultAction)
                Button("Open Project…") { app.showOpenPanel() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProjectView: View {
    let model: ProjectModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter(model: model) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 420)
        } detail: {
            EditorPane(model: model)
        }
        .navigationTitle(model.project.manifest.name)
    }
}

/// The "+" under the file list: click for a new draft, or open the menu for a note.
private struct SidebarFooter: View {
    let model: ProjectModel

    var body: some View {
        HStack {
            Menu {
                Button("New Draft") { model.newFile(kind: .draft) }
                Button("New Note") { model.newFile(kind: .note) }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                model.newFile(kind: .draft)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("New Draft (⌘N). Hold for a note.")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
