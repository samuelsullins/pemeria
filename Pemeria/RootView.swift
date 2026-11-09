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
        .tint(Theme.accentColor)
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
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // The heading, file list, footer and Labels sit in a plain stack. As safe-area insets
            // they pushed on the list's scroll view, and resizing could set off a layout loop.
            FixedMinimumSize(width: 210, height: 300) {
                VStack(spacing: 0) {
                    DocumentsHeader(model: model)
                    Divider()
                    SidebarView(model: model)
                    SidebarFooter(model: model)
                    IconsPane(model: model)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 420)
        } detail: {
            FixedMinimumSize(width: 300, height: 300) {
                EditorArea(model: model)
                    .overlay { SaveConfirmationBar(model: model) }
            }
            .inspector(isPresented: Binding(
                get: { AppModel.shared.rightPanelVisible },
                set: { AppModel.shared.rightPanelVisible = $0 }
            )) {
                FixedMinimumSize(width: 220, height: 300) {
                    RightPanel(model: model)
                }
                .inspectorColumnWidth(min: 220, ideal: 270, max: 420)
            }
        }
        .navigationTitle(model.project.manifest.name)
        .onChange(of: model.iconEditorRequest) { columns = .all }
        .sheet(isPresented: Binding(get: { model.historyFile != nil }, set: { if !$0 { model.historyFile = nil } })) {
            if let id = model.historyFile {
                SnapshotBrowser(model: model, fileID: id)
            }
        }
        .sheet(isPresented: Binding(get: { model.isShowingTrash }, set: { model.isShowingTrash = $0 })) {
            TrashBrowser(model: model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.toggleSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .foregroundStyle(model.isSearching ? Theme.accentColor : Color.primary)
                }
                .help("Search Everything (⌘F)")
                Button {
                    AppModel.shared.rightPanelVisible.toggle()
                } label: {
                    Label("Comments & Bookmarks", systemImage: "sidebar.right")
                }
                .help("Show or hide comments and bookmarks (⌥⌘0)")
            }
        }
    }
}

/// A window column whose smallest size is fixed, whatever is inside it.
///
/// The columns sit in an AppKit split view, which asks each one for its smallest size and
/// re-lays out the whole window whenever that changes. Worked out from the contents, it changed
/// with every step of a drag (text that wraps is taller when narrower), and dragging a divider
/// fast piled up re-layouts until AppKit crashed the app. A GeometryReader takes whatever size
/// it's offered, so the column's smallest size is just the numbers given here.
struct FixedMinimumSize<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: width, minHeight: height)
    }
}

/// "Documents" above the file list, headed like the other sections, with a button for each
/// kind of new file.
private struct DocumentsHeader: View {
    let model: ProjectModel

    var body: some View {
        // On one line like the other headings when the sidebar is wide enough; otherwise the
        // buttons go on a line of their own, so the title and the shortcuts both stay whole.
        WrappingHeaderLayout {
            Text("Documents")
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 10) { buttons }
                .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var buttons: some View {
        Button {
            model.newFile(kind: .draft)
        } label: {
            HeaderWordButton(title: "New Draft", shortcut: "⌘N")
        }
        .help("New Draft (⌘N)")
        Button {
            model.newFile(kind: .note)
        } label: {
            HeaderWordButton(title: "New Note", shortcut: "⌥⌘N")
        }
        .help("New Note (⌥⌘N)")
    }
}

/// A title and its buttons: side by side (buttons at the trailing end) when both fit whole,
/// otherwise the buttons on a second line under the title.
private struct WrappingHeaderLayout: Layout {
    private let spacing: CGFloat = 8
    private let lineSpacing: CGFloat = 6

    private func measure(_ subviews: Subviews, width: CGFloat?) -> (title: CGSize, buttons: CGSize, oneLine: Bool) {
        let title = subviews[0].sizeThatFits(.unspecified)
        let buttons = subviews[1].sizeThatFits(.unspecified)
        let oneLine = width.map { title.width + spacing + buttons.width <= $0 } ?? true
        return (title, buttons, oneLine)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (title, buttons, oneLine) = measure(subviews, width: proposal.width)
        let width = proposal.width ?? (title.width + spacing + buttons.width)
        let height = oneLine ? max(title.height, buttons.height) : title.height + lineSpacing + buttons.height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (title, buttons, oneLine) = measure(subviews, width: bounds.width)
        if oneLine {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width - spacing - buttons.width, height: title.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: title.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + title.height + lineSpacing),
                              anchor: .topLeading, proposal: .unspecified)
        }
    }
}

/// A word, and its shortcut if it has one: every word-button in Pemeria (section headings,
/// the editor header, View Trash). Gray; darker while what it names is on. Use it with
/// `.buttonStyle(.plain)` so the button doesn't tint it.
struct HeaderWordButton: View {
    let title: String
    var shortcut: String?
    var isOn = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isOn ? Theme.buttonOn : Theme.buttonGray)
            if let shortcut { ShortcutHint(keys: shortcut) }
        }
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
    }
}

/// The trash button under the file list.
private struct SidebarFooter: View {
    let model: ProjectModel

    var body: some View {
        HStack {
            Button {
                model.isShowingTrash = true
            } label: {
                HeaderWordButton(title: "View Trash")
            }
            .buttonStyle(.plain)
            .help("See the files moved to the trash, and restore them")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
