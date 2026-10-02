import AppKit
import PemeriaCore
import SwiftUI

/// Colours offered for icons.
enum IconPalette {
    static let colors = [
        "#E5484D", "#F76B15", "#F5A524", "#30A46C", "#12A594", "#0090FF",
        "#3E63DD", "#8E4EC6", "#D6409F", "#BF5F56", "#A18072", "#6E6E73",
    ]
}

/// Symbols offered for icons: plain or `.fill` shapes, no circled variants.
enum IconSymbols {
    static let all = [
        "bolt.fill", "arrow.triangle.turn.up.right.diamond.fill", "exclamationmark.triangle.fill", "flame.fill",
        "checkmark.seal.fill", "star.fill", "sparkles", "heart.fill", "heart.slash.fill", "bolt.heart.fill",
        "flag.fill", "flag.checkered", "bookmark.fill", "eye.fill", "eye.slash.fill", "key.fill",
        "lock.fill", "lock.open.fill", "moon.fill", "sun.max.fill", "sunrise.fill", "sunset.fill",
        "cloud.rain.fill", "cloud.bolt.fill", "snowflake", "wind", "tornado", "water.waves",
        "leaf.fill", "tree.fill", "mountain.2.fill", "globe.americas.fill", "drop.fill", "hourglass",
        "clock.fill", "map.fill", "mappin", "signpost.right.fill", "house.fill", "building.columns.fill",
        "tent.fill", "door.left.hand.open", "bed.double.fill", "person.fill", "person.2.fill", "figure.walk",
        "figure.run", "figure.fall", "figure.2.arms.open", "hand.raised.fill", "brain.head.profile.fill", "eyeglasses",
        "bubble.left.fill", "quote.bubble.fill", "exclamationmark.bubble.fill", "envelope.fill", "phone.fill", "bell.fill",
        "music.note", "theatermasks.fill", "crown.fill", "shield.fill", "xmark.octagon.fill", "questionmark.diamond.fill",
        "lightbulb.fill", "magnifyingglass", "binoculars.fill", "puzzlepiece.fill", "link", "arrow.triangle.branch",
        "arrow.uturn.backward", "infinity", "atom", "wand.and.stars", "scissors", "pencil",
        "paintbrush.fill", "hammer.fill", "wrench.and.screwdriver.fill", "gift.fill", "banknote.fill", "book.fill",
        "newspaper.fill", "camera.fill", "film.fill", "gamecontroller.fill", "dice.fill", "suit.spade.fill",
        "suit.heart.fill", "suit.diamond.fill", "suit.club.fill", "cross.fill", "pills.fill", "bandage.fill",
        "fork.knife", "cup.and.saucer.fill", "car.fill", "airplane", "ferry.fill", "pawprint.fill",
        "hare.fill", "tortoise.fill", "bird.fill", "fish.fill", "ant.fill", "ladybug.fill",
    ]
}

extension IconDefinition {
    var swiftUIColor: Color { Color(nsColor: NSColor(hex: color) ?? .secondaryLabelColor) }
}

/// One icon: its symbol in its colour.
struct IconGlyph: View {
    let icon: IconDefinition
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: icon.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(icon.swiftUIColor)
    }
}

/// A file's icons, overlapping a little and fanned like cards.
struct IconFan: View {
    let icons: [IconDefinition]
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(icons.enumerated()), id: \.offset) { index, icon in
                IconGlyph(icon: icon, size: size)
                    .rotationEffect(.degrees(Self.angle(index, of: icons.count)))
            }
        }
    }

    static func angle(_ index: Int, of count: Int) -> Double {
        switch count {
        case 1: 0
        case 2: [-7, 7][index]
        default: [-10, 0, 10][min(index, 2)]
        }
    }
}

// MARK: - Sidebar pane

/// The Icons pane at the bottom of the sidebar (SPEC.md §4): every icon in the project as a
/// tile. Click a tile to change its look; + adds one.
struct IconsPane: View {
    let model: ProjectModel
    @AppStorage("iconsPaneOpen") private var isOpen = false
    @State private var editing: String?

    private let columns = [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 4)]

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Text("ICONS")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(1.2)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if isOpen {
                    Button {
                        editing = model.addIcon().id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Icon")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if isOpen {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    ForEach(model.project.manifest.icons) { icon in
                        IconTile(icon: icon, isEditing: editing == icon.id) {
                            editing = icon.id
                        }
                        .popover(isPresented: Binding(
                            get: { editing == icon.id },
                            set: { if !$0, editing == icon.id { editing = nil } }
                        ), arrowEdge: .trailing) {
                            IconDetailEditor(model: model, iconID: icon.id) { editing = nil }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .onChange(of: model.iconEditorRequest) {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen = true }
        }
    }
}

private struct IconTile: View {
    let icon: IconDefinition
    let isEditing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            IconGlyph(icon: icon, size: 15)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(isEditing ? 0.12 : hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(icon.name)
    }
}

/// The popover for one icon: a big preview with its name, colour swatches and a symbol grid.
/// Every change is saved straight away.
struct IconDetailEditor: View {
    let model: ProjectModel
    let iconID: String
    let onClose: () -> Void
    @State private var name = ""
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    private var icon: IconDefinition? {
        model.project.manifest.icons.first { $0.id == iconID }
    }

    var body: some View {
        if let icon {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    IconGlyph(icon: icon, size: 26)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(saveName)
                        .onChange(of: nameFocused) { _, focused in if !focused { saveName() } }
                }

                HStack(spacing: 7) {
                    ForEach(IconPalette.colors, id: \.self) { hex in
                        let selected = hex.caseInsensitiveCompare(icon.color) == .orderedSame
                        Button {
                            change { $0.color = hex }
                        } label: {
                            Circle()
                                .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("Custom Colour", selection: Binding(
                        get: { icon.swiftUIColor },
                        set: { color in change { $0.color = NSColor(color).hexString } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .help("Custom colour")
                }

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                        ForEach(IconSymbols.all, id: \.self) { symbol in
                            let selected = symbol == icon.symbol
                            Button {
                                change { $0.symbol = symbol }
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected ? icon.swiftUIColor : Color.secondary)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selected ? icon.swiftUIColor.opacity(0.18) : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 160)

                HStack {
                    Button {
                        model.moveIcon(iconID, by: -1)
                    } label: {
                        Image(systemName: "arrow.left")
                    }
                    .help("Move left")
                    .disabled(model.project.manifest.icons.first?.id == iconID)
                    Button {
                        model.moveIcon(iconID, by: 1)
                    } label: {
                        Image(systemName: "arrow.right")
                    }
                    .help("Move right")
                    .disabled(model.project.manifest.icons.last?.id == iconID)
                    Spacer()
                    Button("Delete Icon", role: .destructive) {
                        if model.usage(of: iconID) > 0 {
                            confirmingDelete = true
                        } else {
                            delete()
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(14)
            .frame(width: 290)
            .onAppear { name = icon.name }
            .onDisappear(perform: saveName)
            .confirmationDialog("Delete “\(icon.name)”?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                let count = model.usage(of: iconID)
                Text(count == 1 ? "1 file uses it and will lose it." : "\(count) files use it and will lose it.")
            }
        }
    }

    private func change(_ edit: (inout IconDefinition) -> Void) {
        guard var icon else { return }
        edit(&icon)
        model.updateIcon(icon)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            name = icon?.name ?? ""
            return
        }
        change { $0.name = trimmed }
    }

    private func delete() {
        onClose()
        model.deleteIcon(iconID)
    }
}

// MARK: - Header picker

/// A single file's name in the header, laid out like its sidebar row: the Working File arrow
/// before it, its icons after (SPEC.md §12). Clicking either opens the icon list, which ends
/// with "Edit Icons…". A faint tag stands in when there are no icons, so there's something to click.
struct HeaderTitleWithIcons<Title: View>: View {
    let model: ProjectModel
    let fileID: FileID
    @ViewBuilder let title: Title
    @State private var showing = false

    var body: some View {
        let icons = model.project.icons(of: fileID)
        let isWorking = model.project.manifest.workingFile == fileID
        HStack(spacing: 6) {
            if isWorking {
                Button {
                    showing.toggle()
                } label: {
                    Image(systemName: "arrowshape.right.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accentColor)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Working File")
            }
            title
            Button {
                showing.toggle()
            } label: {
                Group {
                    if icons.isEmpty {
                        Image(systemName: "tag")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    } else {
                        IconFan(icons: icons, size: 13)
                    }
                }
                .padding(.horizontal, 2)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(icons.isEmpty ? "Add Icons" : icons.map(\.name).joined(separator: ", "))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                IconPickerList(model: model, fileID: fileID) {
                    showing = false
                    model.showIconEditor()
                }
            }
        }
    }
}

/// Every icon with a checkmark, Set/Clear Working File, then "Edit Icons…".
struct IconPickerList: View {
    let model: ProjectModel
    let fileID: FileID
    let onEditIcons: () -> Void

    var body: some View {
        let file = model.project.files[fileID]
        let current = file?.icons ?? []
        let full = model.project.icons(of: fileID).count >= Project.maxIconsPerFile
        let isWorking = model.project.manifest.workingFile == fileID
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.project.manifest.icons) { icon in
                let has = current.contains(icon.id)
                PickerRow(disabled: !has && full) {
                    model.toggleIcon(icon.id, on: [fileID])
                } label: {
                    IconGlyph(icon: icon, size: 13).frame(width: 20)
                    Text(icon.name)
                    Spacer()
                    if has { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                }
            }
            if full {
                Text("Up to \(Project.maxIconsPerFile) icons per file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            Divider().padding(.vertical, 4)
            PickerRow {
                model.setWorkingFile(isWorking ? nil : fileID)
            } label: {
                Image(systemName: "arrowshape.right.fill")
                    .foregroundStyle(Theme.accentColor)
                    .frame(width: 20)
                Text(isWorking ? "Clear Working File" : "Set as Working File")
                Spacer()
            }
            Divider().padding(.vertical, 4)
            PickerRow(action: onEditIcons) {
                Color.clear.frame(width: 20, height: 1)
                Text("Edit Icons…")
                Spacer()
            }
        }
        .padding(6)
        .frame(width: 230)
    }
}

/// A menu-like row: highlights on hover.
private struct PickerRow<Label: View>: View {
    var disabled = false
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accentColor.opacity(hovering && !disabled ? 0.18 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}
