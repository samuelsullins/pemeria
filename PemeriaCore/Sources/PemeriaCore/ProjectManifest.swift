import Foundation

/// A user-defined file icon: shown in the sidebar, up to 3 per file.
public struct IconDefinition: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    /// A hex color, e.g. "#E5484D".
    public var color: String

    public init(id: String, name: String, symbol: String, color: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
    }

    public static let defaults: [IconDefinition] = [
        IconDefinition(id: "inciting-incident", name: "Inciting Incident", symbol: "bolt.fill", color: "#F5A524"),
        IconDefinition(id: "turning-point", name: "Turning Point", symbol: "tornado", color: "#8E4EC6"),
        IconDefinition(id: "crisis", name: "Crisis", symbol: "signpost.right.and.left.fill", color: "#0090FF"),
        IconDefinition(id: "climax", name: "Climax", symbol: "flame.fill", color: "#E5484D"),
        IconDefinition(id: "resolution", name: "Resolution", symbol: "sunrise.fill", color: "#D6409F"),
    ]
}

/// Project-wide settings, stored in `project.json`.
public struct ProjectManifest: Hashable, Sendable, Codable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var name: String
    public var workingFile: FileID?
    public var icons: [IconDefinition]

    public init(name: String, workingFile: FileID? = nil, icons: [IconDefinition] = IconDefinition.defaults) {
        self.formatVersion = Self.currentFormatVersion
        self.name = name
        self.workingFile = workingFile
        self.icons = icons
    }
}
