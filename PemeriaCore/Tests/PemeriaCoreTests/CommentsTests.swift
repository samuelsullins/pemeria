import Foundation
import Testing
@testable import PemeriaCore

struct CommentsTests {
    func texts(_ line: String) -> [String] {
        Comments.ranges(in: line).map { (line as NSString).substring(with: $0) }
    }

    @Test func endsAtLineEndOrSentenceEnd() {
        #expect(texts("// whole line") == ["// whole line"])
        #expect(texts("She climbed. // Too abrupt? Maybe more.") == ["// Too abrupt?"])
        #expect(texts("A // first. B // second!") == ["// first.", "// second!"])
        #expect(texts("Wait // hm… then") == ["// hm…"])
    }

    @Test func needsStartOfLineOrWhitespaceBefore() {
        #expect(texts("see https://example.com now").isEmpty)
        #expect(texts("a//b").isEmpty)
        #expect(texts("\t// tabbed") == ["// tabbed"])
    }

    @Test func knownQuirkEndsAtAbbreviation() {
        #expect(texts("// ask Dr. Smith") == ["// ask Dr."])
    }

    @Test func strippingKeepsStylesAndDropsEmptyLines() {
        let paragraph = Paragraph(runs: [Run("She "), Run("climbed", .italic), Run(". // Too abrupt? Then on.")])
        #expect(Comments.stripped(paragraph) == Paragraph(runs: [Run("She "), Run("climbed", .italic), Run(".  Then on.")]))
        #expect(Comments.stripped(Paragraph("// only a note")) == nil)
        #expect(Comments.stripped(Paragraph("no comment")) == Paragraph("no comment"))
    }

    @Test func listsCommentsAndBookmarksInBookOrder() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let b = project.createFile(kind: .draft, title: "B", after: a.id)
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("Text. // fix this.")),
            .bookmark(Bookmark(id: "bm01", name: "Here")),
        ], outline: [.paragraph(Paragraph("// outline note"))])
        _ = project.setContent(b.id, body: [.paragraph(Paragraph("// in B"))], outline: nil)

        let all = project.comments(in: [a.id, b.id])
        #expect(all.map(\.text) == ["fix this.", "outline note", "in B"])
        #expect(all[1].location.inOutline)
        #expect(project.comments(in: [b.id]).map(\.text) == ["in B"])

        let bookmarks = project.bookmarks()
        #expect(bookmarks.map(\.bookmark.name) == ["Here"])
        #expect(bookmarks[0].location.line == 1)

        _ = project.renameBookmark(at: bookmarks[0].location, to: "There")
        #expect(project.bookmarks().map(\.bookmark.name) == ["There"])
        _ = project.removeBookmark(at: bookmarks[0].location)
        #expect(project.bookmarks().isEmpty)
        #expect(project.files[a.id]!.body.count == 1)
    }
}
