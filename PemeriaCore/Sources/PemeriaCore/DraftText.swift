import Foundation

extension Project {
    /// The text that one-click copy puts on the clipboard (SPEC.md §12): each file's draft text
    /// in book order, with no comments, bookmarks or outline. Paragraphs that held only a
    /// comment are dropped.
    ///
    /// Returns, per file, its kind, whether it's indented, and its paragraphs, so the caller can
    /// style it.
    public func draftText(of ids: [FileID]) -> [(kind: FileKind, indented: Bool, paragraphs: [Paragraph])] {
        let wanted = Set(ids)
        return tree.bookOrder.filter(wanted.contains).compactMap { id in
            guard let file = files[id] else { return nil }
            let paragraphs = Comments.strippedParagraphs(of: file.body).compactMap { $0 }
            return (file.kind, file.indents, paragraphs)
        }
    }

    /// The drafts' outlines in book order, with no comments or bookmarks; notes have none, and
    /// empty outlines are left out.
    public func outlineText(of ids: [FileID]) -> [(id: FileID, paragraphs: [Paragraph])] {
        let wanted = Set(ids)
        return tree.bookOrder.filter(wanted.contains).compactMap { id in
            guard let file = files[id], file.kind == .draft, let outline = file.outline else { return nil }
            let paragraphs = Comments.strippedParagraphs(of: outline).compactMap { $0 }
            return paragraphs.isEmpty ? nil : (id, paragraphs)
        }
    }
}
