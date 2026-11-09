import Foundation
import Testing
@testable import PemeriaCore

struct CommentsTests {
    func texts(_ line: String) -> [String] {
        Comments.ranges(in: line).map { (line as NSString).substring(with: $0) }
    }

    @Test func endsAtLineEndOrBackslash() {
        #expect(texts("// whole line") == ["// whole line"])
        #expect(texts("She climbed. // Too abrupt? Maybe more.") == ["// Too abrupt? Maybe more."])
        #expect(texts("A // first\\ B // second") == ["// first\\", "// second"])
        #expect(texts("// ask Dr. Smith… then") == ["// ask Dr. Smith… then"])
        #expect(texts("She ran // check timeline\\ to the door.") == ["// check timeline\\"])
    }

    @Test func needsStartOfLineOrWhitespaceBefore() {
        #expect(texts("see https://example.com now").isEmpty)
        #expect(texts("a//b").isEmpty)
        #expect(texts("\t// tabbed") == ["// tabbed"])
        #expect(texts("issue#4 and a#b").isEmpty)
    }

    @Test func bookmarksStartWithHash() {
        let line = "Rain came sideways. # Storm starts\\ She ran. // why?"
        let annotations = Comments.annotations(in: line)
        #expect(annotations.map(\.kind) == [.bookmark, .comment])
        #expect(texts(line) == ["# Storm starts\\", "// why?"])
        let name = (line as NSString).substring(with: annotations[0].textRange)
        #expect(name == " Storm starts")
        #expect(annotations[0].isClosed)
        #expect(!annotations[1].isClosed)
        // One inside the other is just part of it.
        #expect(texts("// see # three") == ["// see # three"])
        #expect(texts("# Part // two") == ["# Part // two"])
    }

    @Test func spansLinesWhenClosedLater() {
        let lines = [
            "She ran. // Thinking about this scene:",
            "the pacing drags here",
            "maybe cut the storm\\ She climbed anyway.",
            "Plain prose.",
        ]
        let found = Comments.annotations(inLines: lines)
        func texts(_ index: Int) -> [String] { found[index].map { (lines[index] as NSString).substring(with: $0.range) } }
        #expect(texts(0) == ["// Thinking about this scene:"])
        #expect(texts(1) == ["the pacing drags here"])
        #expect(texts(2) == ["maybe cut the storm\\"])
        #expect(found[3].isEmpty)
        #expect(found[0][0].opensHere && found[0][0].continues)
        #expect(!found[1][0].opensHere && found[1][0].continues)
        #expect(!found[2][0].opensHere && found[2][0].isClosed && !found[2][0].continues)
        #expect(found.flatMap { $0 }.allSatisfy { $0.kind == .comment })
    }

    @Test func endOfLineCommentNeverSwallowsLaterText() {
        // Another comment comes before the backslash, so the first one ends at its line.
        let lines = ["// fix later", "She ran // check\\ to the door."]
        let found = Comments.annotations(inLines: lines)
        #expect(!found[0][0].continues)
        #expect(found[1].count == 1)
        #expect((lines[1] as NSString).substring(with: found[1][0].range) == "// check\\")
        // And with no backslash anywhere, it just ends at the line.
        #expect(Comments.annotations(inLines: ["// note", "Prose."])[1].isEmpty)
        // A bookmark spanning lines, and a done comment staying done on every line.
        let marks = Comments.annotations(inLines: ["# Part one", "the storm\\ Rain."])
        #expect(marks[1][0].kind == .bookmark)
        let done = Comments.annotations(inLines: ["//x long", "note\\"])
        #expect(done[1][0].isDone)
    }

    @Test func strippingAcrossLines() {
        let paragraphs = [Paragraph("She ran. // first"), Paragraph("middle"), Paragraph("end\\  Then on."), Paragraph("Last.")]
        #expect(Comments.stripped(paragraphs) == [Paragraph("She ran."), nil, Paragraph("Then on."), Paragraph("Last.")])
        let blocks: [Block] = paragraphs.map(Block.paragraph)
        #expect(WordCount.count(blocks) == 5)
    }

    @Test func doneMark() {
        func done(_ line: String) -> [Bool] { Comments.annotations(in: line).map(\.isDone) }
        #expect(done("//x fixed the timeline") == [true])
        #expect(done("//X fixed") == [true])
        #expect(done("//x") == [true])
        #expect(done("//x\\ then prose") == [true])
        #expect(done("// x marks the spot") == [false])
        #expect(done("//xylophone") == [false])
        #expect(done("# x") == [false])
        let line = "Text //x fixed\\ more" as NSString
        let comment = Comments.annotations(in: line as String)[0]
        #expect(line.substring(with: comment.textRange) == " fixed")
    }

    @Test func strippingKeepsStylesAndDropsEmptyLines() {
        let paragraph = Paragraph(runs: [Run("She "), Run("climbed", .italic), Run(" // Too abrupt?\\ then on.")])
        #expect(Comments.stripped(paragraph) == Paragraph(runs: [Run("She "), Run("climbed", .italic), Run(" then on.")]))
        #expect(Comments.stripped(Paragraph("// note\\  Then text.")) == Paragraph("Then text."))
        #expect(Comments.stripped(Paragraph("End. // why? And this.")) == Paragraph("End."))
        #expect(Comments.stripped(Paragraph("// only a note")) == nil)
        #expect(Comments.stripped(Paragraph("# Chapter start")) == nil)
        #expect(Comments.stripped(Paragraph("# Storm\\ Rain came.")) == Paragraph("Rain came."))
        #expect(Comments.stripped(Paragraph("no comment")) == Paragraph("no comment"))
    }

    @Test func listsCommentsAndBookmarksInBookOrder() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let b = project.createFile(kind: .draft, title: "B", after: a.id)
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("Text. // fix this.")),
            .bookmark(Bookmark(id: "bm01", name: "Old", offset: 3)),
            .paragraph(Paragraph("Sec # Here\\ ond paragraph. //x done one")),
        ], outline: [.paragraph(Paragraph("// outline note"))])
        _ = project.setContent(b.id, body: [.paragraph(Paragraph("// in B"))], outline: nil)

        let all = project.comments(in: [a.id, b.id])
        #expect(all.map(\.text) == ["fix this.", "done one", "outline note", "in B"])
        #expect(all.map(\.isDone) == [false, true, false, false])
        #expect(all[2].location.inOutline)
        #expect(project.comments(in: [b.id]).map(\.text) == ["in B"])

        // Old-style bookmark lines are ignored; `#` ones are found in the text.
        let bookmarks = project.bookmarks()
        #expect(bookmarks.map(\.name) == ["Here"])
        #expect(bookmarks[0].location.paragraph == 1)
        #expect(bookmarks[0].location.range == NSRange(location: 4, length: 7))
    }

    @Test func listsCommentsSpanningLinesOnce() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("Prose. //x Thinking:")),
            .paragraph(Paragraph("cut the storm\\ More prose.")),
        ], outline: nil)
        let comments = project.comments(in: [a.id])
        #expect(comments.map(\.text) == ["Thinking: cut the storm"])
        #expect(comments[0].isDone)
        #expect(comments[0].location.paragraph == 0)
        #expect(project.setCommentDone(at: comments[0].location, false) != nil)
        #expect(project.files[a.id]!.body[0] == .paragraph(Paragraph("Prose. // Thinking:")))
    }

    @Test func togglesDone() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph(runs: [Run("She ran "), Run("fast", .italic), Run(" // fix\\ then.")])),
            .paragraph(Paragraph("//tighten")),
        ], outline: nil)
        let comments = project.comments(in: [a.id])

        #expect(project.setCommentDone(at: comments[0].location, true) != nil)
        #expect(project.files[a.id]!.body[0] == .paragraph(Paragraph(runs: [Run("She ran "), Run("fast", .italic), Run(" //x fix\\ then.")])))
        // Already done: nothing to change.
        #expect(project.setCommentDone(at: comments[0].location, true) == nil)
        #expect(project.comments(in: [a.id])[0].isDone)

        #expect(project.setCommentDone(at: comments[1].location, true) != nil)
        #expect(project.files[a.id]!.body[1] == .paragraph(Paragraph("//x tighten")))
        #expect(project.comments(in: [a.id])[1].isDone)

        #expect(project.setCommentDone(at: comments[0].location, false) != nil)
        #expect(project.files[a.id]!.body[0] == .paragraph(Paragraph(runs: [Run("She ran "), Run("fast", .italic), Run(" // fix\\ then.")])))
    }
}
