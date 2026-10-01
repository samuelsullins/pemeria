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
