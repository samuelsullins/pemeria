import Foundation

extension Project {
    /// The text that one-click copy puts on the clipboard (SPEC.md §12): each file's draft text
    /// in book order, with no comments, bookmarks or outline. Paragraphs that held only a
    /// comment are dropped.
    ///
    /// Returns, per file, its kind and paragraphs, so the caller can style drafts and notes.
    public func draftText(of ids: [FileID]) -> [(kind: FileKind, paragraphs: [Paragraph])] {
        let wanted = Set(ids)
        return tree.bookOrder.filter(wanted.contains).compactMap { id in
            guard let file = files[id] else { return nil }
            let paragraphs = file.body.compactMap { block -> Paragraph? in
                guard case .paragraph(let paragraph) = block else { return nil }
                return Comments.stripped(paragraph)
            }
            return (file.kind, paragraphs)
        }
    }
}
