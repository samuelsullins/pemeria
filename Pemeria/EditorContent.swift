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

/// What an editor shows: everything inline, or the split used when the outline is pinned.
enum EditorMode: Equatable {
    /// Each file's text, then its outline.
    case full
    /// Draft and note text only (the main editor while the outline is pinned).
    case bodies
    /// Outlines only, each labeled with its file (the pinned outline pane).
    case outlines
    /// Read mode: draft and note text with comments and bookmarks hidden. Not editable.
    case reading
}

/// Which files the editor is showing, and as what. A change means reloading.
struct ShownFile: Equatable {
    let id: FileID
    let kind: FileKind
}

/// Everything an editor shows, laid out as one text:
///
/// ```
/// [header] body \n [divider] \n outline \n [header] body …
/// ```
///
/// Markers and segments are joined by single newlines; each marker is one invisible character
/// on its own line. In `.full` and `.bodies`, headers appear only when more than one file is
/// shown; in `.outlines` every outline gets one. Notes have no outline.
struct EditorContent {
    enum Piece {
        case marker
        case segment(Int)
    }

    var text = NSMutableAttributedString()
    var segments: [EditorSegment] = []
    var markers: [EditorMarker] = []
    /// The order of markers and segments, for rebuilding segment ranges from marker positions.
    var pieces: [Piece] = []

    init(files: [PemeriaFile], mode: EditorMode) {
        for file in files {
            switch mode {
            case .full, .bodies:
                if files.count > 1 {
                    appendMarker(EditorMarker(kind: .fileHeader, fileID: file.id, title: file.title))
                }
                appendSegment(file.id, .body, indented: file.kind == .draft, TextBridge.attributedString(file.body))
                if mode == .full, file.kind == .draft {
                    appendMarker(EditorMarker(kind: .outlineDivider, fileID: file.id, title: file.title))
                    appendSegment(file.id, .outline, indented: false, TextBridge.attributedString(file.outline ?? []))
                }
            case .reading:
                if files.count > 1 {
                    appendMarker(EditorMarker(kind: .fileHeader, fileID: file.id, title: file.title))
                }
                let readable = file.body.compactMap { block -> Block? in
                    guard case .paragraph(let paragraph) = block else { return nil }
                    return Comments.stripped(paragraph).map(Block.paragraph)
                }
                appendSegment(file.id, .body, indented: file.kind == .draft, TextBridge.attributedString(readable))
            case .outlines:
                guard file.kind == .draft else { continue }
                appendMarker(EditorMarker(kind: .fileHeader, fileID: file.id, title: file.title))
                appendSegment(file.id, .outline, indented: false, TextBridge.attributedString(file.outline ?? []))
            }
        }
    }

    private mutating func separate() {
        if !pieces.isEmpty {
            text.append(NSAttributedString(string: "\n"))
        }
    }

    private mutating func appendMarker(_ marker: EditorMarker) {
        separate()
        text.append(NSAttributedString(string: String(TextBridge.markerCharacter), attributes: [.pemeriaMarker: marker]))
        markers.append(marker)
        pieces.append(.marker)
    }

    private mutating func appendSegment(_ id: FileID, _ role: EditorSegment.Role, indented: Bool, _ content: NSAttributedString) {
        separate()
        let start = text.length
        text.append(content)
        pieces.append(.segment(segments.count))
        segments.append(EditorSegment(fileID: id, role: role, isIndented: indented, range: NSRange(location: start, length: content.length)))
    }
}
