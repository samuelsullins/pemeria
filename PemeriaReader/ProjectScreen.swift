import PemeriaCore
import SwiftUI

/// A project's files, nested and folded like the Mac's sidebar. Tapping a file reads it
/// together with everything nested inside it.
struct ProjectScreen: View {
    let library: Library
    let projectID: UUID

    var body: some View {
        if let reader = library.reader(for: projectID) {
            ProjectContents(reader: reader)
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
        }
    }
}

private struct ProjectContents: View {
    let reader: ProjectReader

    var body: some View {
        Group {
            if let project = reader.project {
                List {
                    if let working = project.manifest.workingFile, project.files[working] != nil {
                        Section("Working File") {
                            FileLink(id: working, project: project, reader: reader)
                        }
                    }
                    Section {
                        FileRows(ids: project.children(of: nil), project: project, reader: reader)
                    }
                }
                .refreshable { await reader.refresh() }
                .overlay {
                    if project.files.isEmpty {
                        ContentUnavailableView("No Files", systemImage: "doc.text", description: Text("This project is empty."))
                    }
                }
            } else {
                ProjectStatusView(status: reader.status)
            }
        }
        .navigationTitle(reader.project?.manifest.name ?? reader.name)
        .navigationSubtitle(reader.project == nil ? "" : "\(reader.totals.totalDraft.formatted()) words")
    }
}

/// Files at one level, each followed (when unfolded) by the files nested in it.
private struct FileRows: View {
    let ids: [FileID]
    let project: Project
    let reader: ProjectReader

    var body: some View {
        ForEach(ids, id: \.self) { id in
            let children = project.children(of: id)
            if children.isEmpty {
                FileLink(id: id, project: project, reader: reader)
            } else {
                DisclosureGroup(isExpanded: reader.isExpanded(id)) {
                    FileRows(ids: children, project: project, reader: reader)
                } label: {
                    FileLink(id: id, project: project, reader: reader)
                }
            }
        }
    }
}

private struct FileLink: View {
    let id: FileID
    let project: Project
    let reader: ProjectReader

    var body: some View {
        if let file = project.files[id] {
            NavigationLink(value: Route.file(reader.id, id)) {
                HStack(spacing: 8) {
                    if file.kind == .note {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                    }
                    Text(file.title)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    IconFan(icons: project.icons(of: id))
                    let words = reader.words(inTree: id)
                    if words > 0 {
                        Text(words.formatted())
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
