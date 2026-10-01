import AppKit
import PemeriaCore
import SwiftUI

/// The Edit Icons sheet (SPEC.md §4): the project's icon definitions, each with a name, a
/// colour and a symbol. Drag to reorder. Changes apply on Save.
struct IconEditor: View {
    let model: ProjectModel
    @State private var icons: [IconDefinition]
    @Environment(\.dismiss) private var dismiss

    init(model: ProjectModel) {
        self.model = model
        _icons = State(initialValue: model.project.manifest.icons)
    }

    static let symbols = [
        "bolt.fill", "arrow.triangle.turn.up.right.diamond.fill", "exclamationmark.triangle.fill", "flame.fill",
        "checkmark.seal.fill", "star.fill", "heart.fill", "heart.slash.fill", "flag.fill", "bookmark.fill",
        "eye.fill", "key.fill", "lock.fill", "moon.fill", "sun.max.fill", "cloud.rain.fill", "snowflake",
        "leaf.fill", "drop.fill", "hourglass", "clock.fill", "map.fill", "house.fill", "building.columns.fill",
        "person.fill", "person.2.fill", "figure.walk", "bubble.left.fill", "envelope.fill", "music.note",
        "theatermasks.fill", "crown.fill", "shield.fill", "skull.fill", "questionmark", "lightbulb.fill",
        "magnifyingglass", "puzzlepiece.fill", "link", "scissors", "pencil", "sparkles",
    ]

    static let palette = ["#E5484D", "#F5A524", "#D6409F", "#8E4EC6", "#30A46C", "#0090FF", "#12A594", "#BF5F56", "#6E6E73"]

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit Icons")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)
            List {
                ForEach($icons) { $icon in
                    IconRow(icon: $icon) {
                        icons.removeAll { $0.id == icon.id }
                    }
                }
                .onMove { icons.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)
            HStack {
                Button {
                    let used = Set(icons.map(\.color))
                    icons.append(IconDefinition(
                        id: IconDefinition.generateID(avoiding: icons),
                        name: "New Icon",
                        symbol: "star.fill",
                        color: Self.palette.first { !used.contains($0) } ?? Self.palette[0]
                    ))
                } label: {
                    Label("New Icon", systemImage: "plus")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.setIconDefinitions(icons.map { icon in
                        var icon = icon
                        let name = icon.name.trimmingCharacters(in: .whitespaces)
                        icon.name = name.isEmpty ? "Untitled" : name
                        return icon
                    })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 420)
    }
}

private struct IconRow: View {
    @Binding var icon: IconDefinition
    let onDelete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(IconEditor.symbols, id: \.self) { symbol in
                    Button {
                        icon.symbol = symbol
                    } label: {
                        Label(symbol, systemImage: symbol)
                    }
                }
            } label: {
                Badge(icon: icon)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a symbol")

            TextField("Name", text: $icon.name)
                .textFieldStyle(.roundedBorder)

            ColorPicker("Colour", selection: Binding(
                get: { Color(nsColor: NSColor(hex: icon.color) ?? .gray) },
                set: { icon.color = NSColor($0).hexString }
            ), supportsOpacity: false)
            .labelsHidden()

            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Delete this icon")
            .confirmationDialog("Delete “\(icon.name)”?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive, action: onDelete)
            } message: {
                Text("Files using it will lose it when you save.")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The same disc-and-symbol badge the sidebar draws.
private struct Badge: View {
    let icon: IconDefinition

    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: NSColor(hex: icon.color) ?? .gray))
            Image(systemName: icon.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 24, height: 24)
    }
}
