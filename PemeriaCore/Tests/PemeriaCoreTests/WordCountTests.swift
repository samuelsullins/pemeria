import Foundation
import Testing
@testable import PemeriaCore

struct WordCountTests {
    @Test func countsLikeMicrosoftWord() {
        #expect(WordCount.count("") == 0)
        #expect(WordCount.count("  The lamp  was dark. ") == 4)
        #expect(WordCount.count("a well-known word") == 3)
        #expect(WordCount.count("This—in my opinion—is wrong") == 4)
        #expect(WordCount.count("This — in my opinion — is wrong") == 8)
        #expect(WordCount.count("Wait… what? 1,200 people.") == 4)
        #expect(WordCount.count("She said, “Don’t.”") == 3)
        #expect(WordCount.count("line one\nline two\ttab") == 5)
        #expect(WordCount.count("Rain \u{2060}came. \u{2060} ") == 2)
    }

    @Test func countsPartOfALineWithoutComments() {
        let line = "She ran home. // too fast? Then slept."
        let whole = NSRange(location: 0, length: (line as NSString).length)
        #expect(WordCount.count(in: whole, ofLine: line) == 5)
        // Starting inside the comment still skips it.
        #expect(WordCount.count(in: NSRange(location: 18, length: whole.length - 18), ofLine: line) == 2)
        #expect(WordCount.count(in: NSRange(location: 0, length: 7), ofLine: line) == 2)
        #expect(WordCount.count(in: NSRange(location: 4, length: 0), ofLine: line) == 0)
    }

    @Test func leavesOutCommentsBookmarksAndNotes() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let b = project.createFile(kind: .draft, title: "B", after: a.id)
        let note = project.createFile(kind: .note, title: "N", after: b.id)
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("One two three. // not these words.")),
            .bookmark(Bookmark(id: "bm01", name: "Mark here", offset: 0)),
            .paragraph(Paragraph(runs: [Run("Four "), Run("five", .italic)])),
            .paragraph(Paragraph("// a whole comment line")),
        ], outline: [.paragraph(Paragraph("Outline words here"))])
        _ = project.setContent(b.id, body: [.paragraph(Paragraph("Six seven"))], outline: nil)
        _ = project.setContent(note.id, body: [.paragraph(Paragraph("Notes never count"))], outline: nil)

        #expect(project.wordCounts(selected: [a.id, note.id]) == WordCounts(selectedDraft: 5, selectedOutline: 3, totalDraft: 7, totalOutline: 3))
        #expect(project.wordCounts(selected: []) == WordCounts(totalDraft: 7, totalOutline: 3))
    }
}

struct IconsAndWorkingFileTests {
    @Test func togglesIconsUpToThree() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let b = project.createFile(kind: .draft, title: "B", after: a.id)
        let ids = IconDefinition.defaults.map(\.id)

        let first = project.toggleIcon(ids[0], on: [a.id])
        #expect(first.count == 1)
        // Mixed: added only where missing.
        let mixed = project.toggleIcon(ids[0], on: [a.id, b.id])
        #expect(mixed.map(\.id) == [b.id])
        // Everyone has it: removed from all.
        let removed = project.toggleIcon(ids[0], on: [a.id, b.id])
        #expect(removed.count == 2)
        #expect(project.files[a.id]!.icons.isEmpty)

        for id in ids { _ = project.toggleIcon(id, on: [a.id]) }
        #expect(project.files[a.id]!.icons == Array(ids.prefix(3)))
        #expect(project.icons(of: a.id).map(\.id) == Array(ids.prefix(3)))
        let unknown = project.toggleIcon("nope", on: [a.id])
        #expect(unknown.isEmpty)
    }

    @Test func removingADefinitionClearsItFromFiles() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.toggleIcon("climax", on: [a.id])
        _ = project.toggleIcon("crisis", on: [a.id])
        let changed = project.setIconDefinitions(IconDefinition.defaults.filter { $0.id != "climax" })
        #expect(changed.map(\.id) == [a.id])
        #expect(project.files[a.id]!.icons == ["crisis"])
        let fresh = IconDefinition.generateID(avoiding: project.manifest.icons)
        #expect(fresh.hasPrefix("icon-") && !project.manifest.icons.contains { $0.id == fresh })
    }

    @Test func workingFile() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let set = project.setWorkingFile(a.id)
        let again = project.setWorkingFile(a.id)
        let unknown = project.setWorkingFile("zzzz")
        #expect(set && !again && !unknown)
        #expect(project.manifest.workingFile == a.id)
        _ = project.remove([a.id])
        #expect(project.manifest.workingFile == nil)
    }

    @Test func draftTextDropsCommentsBookmarksAndOutline() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let b = project.createFile(kind: .note, title: "B", after: a.id)
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("First. // fix.")),
            .bookmark(Bookmark(id: "bm01", name: "x", offset: 2)),
            .paragraph(Paragraph(runs: [Run("Second "), Run("one", .italic)])),
            .paragraph(Paragraph("// only a comment")),
            .paragraph(Paragraph(runs: [])),
        ], outline: [.paragraph(Paragraph("outline"))])
        _ = project.setContent(b.id, body: [.paragraph(Paragraph("Note."))], outline: nil)
        let text = project.draftText(of: [b.id, a.id])
        #expect(text.map(\.kind) == [.draft, .note])
        #expect(text[0].paragraphs == [Paragraph("First."), Paragraph(runs: [Run("Second "), Run("one", .italic)]), Paragraph(runs: [])])
        #expect(text[1].paragraphs == [Paragraph("Note.")])
    }
}
