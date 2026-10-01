import AppKit
import PemeriaCore

extension NSAttributedString.Key {
    /// An `EditorMarker` on the invisible character of a file-header or outline-divider line.
    static let pemeriaMarker = NSAttributedString.Key("com.samuelsullins.pemeria.marker")
}

/// A non-editable line between editable stretches: the label above each file when several
/// are shown, or the divider before a file's outline.
final class EditorMarker: NSObject {
    enum Kind {
        case fileHeader
        case outlineDivider
    }

    let kind: Kind
    let fileID: FileID
    var title: String

    init(kind: Kind, fileID: FileID, title: String) {
        self.kind = kind
        self.fileID = fileID
        self.title = title
    }
}

/// An editable stretch of the editor's text: one file's body or outline.
struct EditorSegment {
    enum Role {
        case body
        case outline
    }

    let fileID: FileID
    let role: Role
    /// Draft prose gets book-style first-line indents; outlines and notes don't.
    let isIndented: Bool
    var range: NSRange

    /// Whether an edit to `range` falls entirely inside this segment (touching either end counts).
    func contains(_ other: NSRange) -> Bool {
        range.location <= other.location && NSMaxRange(other) <= NSMaxRange(range)
    }
}

/// Which files the editor is showing, and as what. A change means reloading.
struct ShownFile: Equatable {
    let id: FileID
    let kind: FileKind
}

/// Everything the editor shows, laid out as one text:
///
/// ```
/// [header] body \n [divider] \n outline \n [header] body …
/// ```
///
/// Markers and segments are joined by single newlines; each marker is one invisible character
/// on its own line. Headers appear only when more than one file is shown; notes have no outline.
struct EditorContent {
    var text = NSMutableAttributedString()
    var segments: [EditorSegment] = []
    var markers: [EditorMarker] = []

    init(files: [PemeriaFile]) {
        for file in files {
            if files.count > 1 {
                appendMarker(EditorMarker(kind: .fileHeader, fileID: file.id, title: file.title))
            }
            appendSegment(file.id, .body, indented: file.kind == .draft, TextBridge.attributedString(file.body))
            if file.kind == .draft {
                appendMarker(EditorMarker(kind: .outlineDivider, fileID: file.id, title: file.title))
                appendSegment(file.id, .outline, indented: false, TextBridge.attributedString(file.outline ?? []))
            }
        }
    }

    private mutating func separate() {
        if text.length > 0 || !segments.isEmpty || !markers.isEmpty {
            text.append(NSAttributedString(string: "\n"))
        }
    }

    private mutating func appendMarker(_ marker: EditorMarker) {
        separate()
        text.append(NSAttributedString(string: String(TextBridge.markerCharacter), attributes: [.pemeriaMarker: marker]))
        markers.append(marker)
    }

    private mutating func appendSegment(_ id: FileID, _ role: EditorSegment.Role, indented: Bool, _ content: NSAttributedString) {
        separate()
        let start = text.length
        text.append(content)
        segments.append(EditorSegment(fileID: id, role: role, isIndented: indented, range: NSRange(location: start, length: content.length)))
    }
}
