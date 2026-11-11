import Foundation

/// Converts a whole file to and from the text stored in `files/<id>.md`. See SPEC.md §2.
///
/// ```
/// ---
/// id: k3f9a2
/// title: The Lighthouse
/// parent:
/// order: V
/// kind: draft
/// icons: inciting-incident, -, crisis
/// ---
/// The lamp had been dark for *eleven* years.
/// <!-- bookmark b7c1 @12: The storm starts -->
/// <!-- outline -->
/// Mara reaches the lighthouse.
/// ```
///
/// Decoding never fails: anything unexpected is read as prose rather than thrown away.
public enum FileCodec {
    static let knownKeys: Set<String> = ["id", "title", "parent", "order", "kind", "icons", "indent"]
    static let frontMatterFence = "---"
    static let outlineDivider = "<!-- outline -->"
    static let bookmarkPrefix = "<!-- bookmark "
    static let markerSuffix = " -->"
    /// Stands for an empty label slot in the `icons:` line, so the slots after it keep their places.
    static let emptySlot = "-"

    public static func encode(_ file: PemeriaFile) -> String {
        let file = file.canonicalized()
        var lines = [frontMatterFence]
        lines.append(field("id", file.id.rawValue))
        lines.append(field("title", file.title))
        lines.append(field("parent", file.parent?.rawValue ?? ""))
        lines.append(field("order", file.order))
        lines.append(field("kind", file.kind.rawValue))
        lines.append(field("icons", file.icons.map { $0.isEmpty ? emptySlot : $0 }.joined(separator: ", ")))
        // Only written once chosen, so files that never touched it are unchanged.
        if let indent = file.indent { lines.append(field("indent", indent ? "yes" : "no")) }
        lines += file.extraFields.map { field($0.key, $0.value) }
        lines.append(frontMatterFence)
        lines += file.body.map(encode)
        if let outline = file.outline {
            lines.append(outlineDivider)
            lines += outline.map(encode)
        }
        return lines.map { $0 + "\n" }.joined()
    }

    /// `fallbackID` is used when the text has no valid id of its own (usually the file's name).
    public static func decode(_ text: String, fallbackID: FileID) -> PemeriaFile {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }

        var file = PemeriaFile(id: fallbackID, title: fallbackID.rawValue, order: "", body: [], outline: nil)

        if lines.first == frontMatterFence,
           let closing = lines.dropFirst().firstIndex(of: frontMatterFence) {
            for line in lines[1..<closing] {
                guard let (key, value) = splitField(line) else { continue }
                switch key {
                case "id": if let id = FileID(value) { file.id = id }
                case "title": file.title = value
                case "parent": file.parent = FileID(value)
                case "order": file.order = value
                case "kind": file.kind = FileKind(rawValue: value) ?? .draft
                case "indent":
                    switch value.lowercased() {
                    case "yes", "true": file.indent = true
                    case "no", "false": file.indent = false
                    default: file.extraFields.append(ExtraField(key: key, value: value))
                    }
                case "icons":
                    // Positional: "-" (or nothing) between commas is an empty slot.
                    file.icons = value.split(separator: ",", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                default: file.extraFields.append(ExtraField(key: key, value: value))
                }
            }
            lines.removeSubrange(0...closing)
        }

        if let divider = lines.firstIndex(of: outlineDivider) {
            file.body = lines[..<divider].map(decodeBlock)
            file.outline = lines[(divider + 1)...].map(decodeBlock)
        } else {
            file.body = lines.map(decodeBlock)
        }
        return file.canonicalized()
    }

    private static func field(_ key: String, _ value: String) -> String {
        value.isEmpty ? "\(key):" : "\(key): \(value)"
    }

    private static func encode(_ block: Block) -> String {
        switch block {
        case .paragraph(let paragraph):
            return InlineCodec.encode(paragraph)
        case .bookmark(let bookmark):
            let key = bookmark.offset > 0 ? "\(bookmark.id) @\(bookmark.offset)" : bookmark.id
            return "\(bookmarkPrefix)\(field(key, bookmark.name))\(markerSuffix)"
        }
    }

    private static func decodeBlock(_ line: String) -> Block {
        if let bookmark = decodeBookmark(line) {
            return .bookmark(bookmark)
        }
        return .paragraph(InlineCodec.decode(line))
    }

    private static func decodeBookmark(_ line: String) -> Bookmark? {
        guard line.hasPrefix(bookmarkPrefix), line.hasSuffix(markerSuffix),
              line.count >= bookmarkPrefix.count + markerSuffix.count else { return nil }
        let scalars = line.unicodeScalars
        let inner = String(String.UnicodeScalarView(
            scalars.dropFirst(bookmarkPrefix.unicodeScalars.count).dropLast(markerSuffix.unicodeScalars.count)
        ))
        guard let (key, name) = splitField(inner) else { return nil }
        // "b7c1" or "b7c1 @12"
        let parts = key.split(separator: " ", omittingEmptySubsequences: false)
        let id = String(parts[0])
        guard Identifier.isValid(id) else { return nil }
        var offset = 0
        if parts.count == 2, parts[1].hasPrefix("@"), let value = Int(parts[1].dropFirst()), value >= 0, String(value) == parts[1].dropFirst() {
            offset = value
        } else if parts.count != 1 {
            return nil
        }
        return Bookmark(id: id, name: name, offset: offset)
    }

    /// Splits `key: value` at the first colon, dropping one space after it.
    /// Works on scalars: a value starting with an accent mustn't hide that space.
    private static func splitField(_ line: String) -> (String, String)? {
        let scalars = line.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":") else { return nil }
        var value = scalars[scalars.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(String.UnicodeScalarView(scalars[..<colon])), String(String.UnicodeScalarView(value)))
    }
}
