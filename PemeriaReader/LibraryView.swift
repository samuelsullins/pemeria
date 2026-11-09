import PemeriaCore
import SwiftUI
import UniformTypeIdentifiers

/// The first screen: projects opened before, and a button to open another from Files.
struct LibraryView: View {
    @Bindable var library: Library
    @State private var importing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $library.path) {
            List {
                ForEach(library.sortedRecents) { recent in
                    NavigationLink(value: Route.project(recent.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recent.name)
                                .font(.system(.title3, design: .serif))
                            Text("Opened \(recent.lastOpened, format: .relative(presentation: .named))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            library.remove(recent.id)
                        }
                    }
                }
            }
            .overlay {
                if library.recents.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "books.vertical")
                    } description: {
                        Text("Save a project to iCloud Drive on your Mac, then open it here to read it.")
                    } actions: {
                        Button("Open Project") { importing = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Pemeria")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open Project", systemImage: "folder") { importing = true }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .project(let id):
                    ProjectScreen(library: library, projectID: id)
                case .file(let id, let fileID):
                    ReaderScreen(library: library, projectID: id, fileID: fileID)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pemeriaProject, .folder]) { result in
            switch result {
            case .success(let url): library.add(url)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .alert("Can’t Open Project", isPresented: Binding(
            get: { library.error != nil },
            set: { if !$0 { library.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.error ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshOpenProjects() }
        }
    }
}

/// Shown while a project is being read, or when it can't be.
struct ProjectStatusView: View {
    let status: ProjectReader.Status

    var body: some View {
        switch status {
        case .downloading(let remaining):
            VStack(spacing: 8) {
                ProgressView()
                Text("Downloading from iCloud")
                Text(remaining == 1 ? "1 item to go" : "\(remaining) items to go")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            ContentUnavailableView("Can’t Open Project", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loading, .ready:
            ProgressView()
        }
    }
}
