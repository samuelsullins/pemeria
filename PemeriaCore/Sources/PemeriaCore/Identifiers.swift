import Foundation

/// Identifies a file in a project. Also used as the file's name on disk (`files/<id>.md`),
/// so it is restricted to lowercase letters and digits.
public struct FileID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Returns nil unless `rawValue` is a valid identifier.
    public init?(_ rawValue: String) {
        guard Identifier.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        precondition(Identifier.isValid(value), "Invalid FileID literal: \(value)")
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Identifier.isValid(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid file id: \(raw)")
        }
        self.rawValue = raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: FileID, rhs: FileID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { rawValue }

    /// A new random identifier that isn't in `existing`.
    public static func generate<S: Sequence>(avoiding existing: S) -> FileID where S.Element == FileID {
        let taken = Set(existing.map(\.rawValue))
        return FileID(uncheckedRawValue: Identifier.generate(length: 6, avoiding: taken))
    }

    private init(uncheckedRawValue: String) {
        self.rawValue = uncheckedRawValue
    }
}

enum Identifier {
    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { alphabet.contains($0) }
    }

    static func generate(length: Int, avoiding taken: Set<String>) -> String {
        while true {
            let candidate = String((0..<length).map { _ in alphabet.randomElement()! })
            if !taken.contains(candidate) { return candidate }
        }
    }
}
