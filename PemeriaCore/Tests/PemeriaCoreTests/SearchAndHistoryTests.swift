import Foundation
import Testing
@testable import PemeriaCore

struct SearchTests {
    func sample() -> (Project, FileID, FileID) {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "The Lighthouse")
        let n = project.createFile(kind: .note, title: "Lamp notes", after: a.id)
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("The lamp was dark. // brighter lamp?")),
            .bookmark(Bookmark(id: "bm01", name: "Lamp goes out", offset: 4)),
            .paragraph(Paragraph(runs: [Run("A "), Run("lámp", .italic), Run(" again.")])),
        ], outline: [.paragraph(Paragraph("Lamp scene"))])
        _ = project.setContent(n.id, body: [.paragraph(Paragraph("Research: LAMP oil"))], outline: nil)
        return (project, a.id, n.id)
    }

    @Test func searchesEverythingGroupedByKind() {
        let (project, a, n) = sample()
        let results = project.search("lamp")
        #expect(results.map(\.kind) == [.fileName, .draft, .draft, .note, .outline, .comment, .bookmark])
        #expect(results[0].fileID == n)
        #expect(results[1].location == TextLocation(fileID: a, inOutline: false, paragraph: 0, range: NSRange(location: 4, length: 4)))
        // Accents and case are ignored; paragraph index skips the bookmark.
        #expect(results[2].location?.paragraph == 1)
        #expect(results[4].location?.inOutline == true)
        #expect(results[6].bookmarkID == "bm01")
        #expect(project.search("  ").isEmpty)
        #expect(project.search("lamp", limit: 1).filter { $0.kind == .draft }.count == 1)
    }

    @Test func findsWholeWordsAcrossStyleRunsAndCurlyText() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph(runs: [Run("“That’s "), Run("cra", .italic), Run("zy,” she said.")])),
            .paragraph(Paragraph("Utterly crazy. // crazy note.")),
        ], outline: nil)
        for query in ["crazy", "CRAZY", "CrAzY", "zy", "crazy,", "That’s crazy", "THAT'S CRAZY", "\"that's", "ｃｒａｚｙ"] {
            #expect(!project.search(query).isEmpty, "\(query)")
        }
        #expect(project.search("crazy").map(\.kind) == [.draft, .draft, .comment])
    }

    @Test func matchCaseAndWholeWords() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.setContent(a.id, body: [.paragraph(Paragraph("Al said Also. AL’s hat, al dente."))], outline: nil)
        #expect(project.search("al").count == 4)
        #expect(project.search("Al", options: SearchOptions(matchCase: true)).count == 2)
        let whole = project.search("al", options: SearchOptions(wholeWords: true))
        #expect(whole.map(\.matchedText) == ["Al", "AL", "al"])
        #expect(project.search("Al", options: SearchOptions(matchCase: true, wholeWords: true)).map(\.matchedText) == ["Al"])
        // An edge that isn't a letter needs no boundary.
        #expect(project.search("'s", options: SearchOptions(wholeWords: true)).map(\.matchedText) == ["’s"])
    }

    @Test func scopeLimitsFiles() {
        let (project, a, n) = sample()
        #expect(Set(project.search("lamp", options: SearchOptions(scope: [n])).map(\.fileID)) == [n])
        #expect(!project.search("lamp", options: SearchOptions(scope: [a])).contains { $0.fileID == n })
    }

    @Test func plusFindsParagraphsWithEveryTerm() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "Mira and Kate")
        _ = project.setContent(a.id, body: [
            .paragraph(Paragraph("Mira left.")),
            .paragraph(Paragraph("Kate shoved Mira into the rail.")),
            .paragraph(Paragraph("Kate alone.")),
        ], outline: nil)
        #expect(Project.searchTerms("Mira + Kate") == ["Mira", "Kate"])
        #expect(Project.searchTerms("Mira +") == ["Mira"])
        let results = project.search("mira + kate")
        #expect(results.count == 1)
        #expect(results[0].location?.paragraph == 1)
        #expect(results[0].matchedText == "Kate")
        #expect(results[0].otherMatchRanges.map { (results[0].snippet as NSString).substring(with: $0) } == ["Mira"])
    }

    @Test func wordFormsFindOtherFormsOfAWord() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.setContent(a.id, body: [.paragraph(Paragraph("She ran. They were running. He runs. A rune."))], outline: nil)
        let found = project.search("run", options: SearchOptions(wordForms: true)).map(\.matchedText)
        #expect(found == ["ran", "running", "runs"])
    }

    @Test func replaceKeepsCaseStylesAndBookmarks() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "Bob’s scene")
        _ = project.setContent(a.id, body: [
            .bookmark(Bookmark(id: "b1", name: "Bob arrives", offset: 0)),
            .bookmark(Bookmark(id: "b2", name: "end", offset: 19)),
            .paragraph(Paragraph(runs: [Run("bob and "), Run("Bob", .italic), Run(" and BOB.")])),
        ], outline: [.paragraph(Paragraph("Bob // Bob again."))])
        let results = project.search("bob", options: SearchOptions(wholeWords: true), limit: .max)
        let (changed, count) = project.replace(results, with: "Dave", preservingCase: true)
        #expect(count == 7)
        #expect(changed.count == 1)
        let file = project.files[a.id]!
        #expect(file.title == "Dave’s scene")
        #expect(file.body == [
            .bookmark(Bookmark(id: "b1", name: "Dave arrives", offset: 0)),
            .bookmark(Bookmark(id: "b2", name: "end", offset: 22)),
            .paragraph(Paragraph(runs: [Run("dave and "), Run("Dave", .italic), Run(" and DAVE.")])),
        ])
        #expect(file.outline == [.paragraph(Paragraph("Dave // Dave again."))])
    }

    @Test func replaceSkipsStaleResultsAndSomeResults() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        _ = project.setContent(a.id, body: [.paragraph(Paragraph("lamp, lamp, lamp"))], outline: nil)
        let results = project.search("lamp")
        _ = project.setContent(a.id, body: [.paragraph(Paragraph("lamp, LOMP, lamp"))], outline: nil)
        // The middle one has changed; the first is left out on purpose.
        let (_, count) = project.replace(Array(results.dropFirst()), with: "lantern", preservingCase: false)
        #expect(count == 1)
        #expect(project.files[a.id]!.body == [.paragraph(Paragraph("lamp, LOMP, lantern"))])
    }

    @Test func matchingCase() {
        #expect(Project.matchingCase(of: "bob", "Dave") == "dave")
        #expect(Project.matchingCase(of: "Bob", "dave") == "Dave")
        #expect(Project.matchingCase(of: "BOB", "Dave") == "DAVE")
        #expect(Project.matchingCase(of: "I", "we") == "We")
        #expect(Project.matchingCase(of: "kay", "McKay") == "mcKay")
        #expect(Project.matchingCase(of: "Kay", "McKay") == "McKay")
    }

    @Test func snippetsCutAtWordsWithEllipses() {
        let text = String(repeating: "word ", count: 40) + "needle " + String(repeating: "more ", count: 40)
        let ns = text as NSString
        let match = ns.range(of: "needle")
        let (snippet, range) = Project.snippet(of: ns, around: match)
        #expect(snippet.hasPrefix("…word"))
        #expect(snippet.hasSuffix("…"))
        #expect((snippet as NSString).substring(with: range) == "needle")
        let short = Project.snippet(of: "a needle" as NSString, around: NSRange(location: 2, length: 6))
        #expect(short.0 == "a needle")
    }
}

struct HistoryTests {
    func makePackage() throws -> (ProjectPackage, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).pemeria")
        return (try ProjectPackage.create(at: url, name: "x"), url)
    }

    @Test func versionsAndTrashRoundTrip() throws {
        let (package, url) = try makePackage()
        defer { try? FileManager.default.removeItem(at: url) }
        var project = Project(try package.load())
        let parent = project.createFile(kind: .draft, title: "Part")
        var child = project.createFile(kind: .draft, title: "Scene", after: parent.id)
        _ = project.move([child.id], into: parent.id, at: 0)
        child = project.setContent(child.id, body: [.paragraph(Paragraph("First version."))], outline: nil)!
        for file in project.files.values { try package.write(file) }

        try package.snapshot(child.id, date: Date(timeIntervalSince1970: 1000))
        child = project.setContent(child.id, body: [.paragraph(Paragraph("Second version."))], outline: nil)!
        try package.write(child)
        try package.snapshot(child.id, date: Date(timeIntervalSince1970: 2000))
        let versions = package.versions(of: child.id)
        #expect(versions.map(\.date) == [Date(timeIntervalSince1970: 2000), Date(timeIntervalSince1970: 1000)])
        #expect(try package.read(versions[1], of: child.id).body == [.paragraph(Paragraph("First version."))])

        // Trash both, then restore only the child: it lands at the top level.
        let removed = project.remove([parent.id])
        for id in removed { try package.moveToTrash(id) }
        let trashed = package.trashedFiles()
        #expect(Set(trashed.map(\.file.id)) == [parent.id, child.id])
        let entry = try #require(trashed.first { $0.file.id == child.id })
        let restored = project.restore(entry.file)
        #expect(restored[0].id == child.id && restored[0].parent == nil)
        try package.restore(entry, as: restored[0])
        #expect(package.trashedFiles().map(\.file.id) == [parent.id])
        #expect(project.tree.roots == [child.id])

        try package.emptyTrash(keepingSnapshotsOf: Set(project.files.keys))
        #expect(package.trashedFiles().isEmpty)
        #expect(package.versions(of: child.id).count == 2)
    }

    @Test func restoringOverATakenIDGetsANewOne() {
        var project = Project(manifest: ProjectManifest(name: "x"), files: [:])
        let a = project.createFile(kind: .draft, title: "A")
        let restored = project.restore(PemeriaFile(id: a.id, title: "Old A", parent: "gone", order: "", kind: .draft))
        #expect(restored[0].id != a.id)
        #expect(restored[0].parent == nil)
        #expect(project.files.count == 2)
    }
}
