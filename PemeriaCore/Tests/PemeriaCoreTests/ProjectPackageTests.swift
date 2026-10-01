import Foundation
import Testing
@testable import PemeriaCore

struct ProjectPackageTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "PemeriaCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makePackage() throws -> ProjectPackage {
        try ProjectPackage.create(at: root.appending(path: "Novel.pemeria"), name: "Novel")
    }

    @Test func createsAndReloadsAnEmptyProject() throws {
        let package = try makePackage()
        let loaded = try package.load()
        #expect(loaded.manifest.name == "Novel")
        #expect(loaded.manifest.icons == IconDefinition.defaults)
        #expect(loaded.files.isEmpty)
        #expect(loaded.problems.isEmpty)
    }

    @Test func refusesToCreateOverExistingProject() throws {
        _ = try makePackage()
        #expect(throws: (any Error).self) { try makePackage() }
    }

    @Test func writesAndReloadsFiles() throws {
        let package = try makePackage()
        let chapter = PemeriaFile(id: "ch0001", title: "Chapter One", order: "V")
        let scene = PemeriaFile(
            id: "sc0001",
            title: "The Lighthouse",
            parent: "ch0001",
            order: "V",
            body: [.paragraph(Paragraph(runs: [Run("The lamp was "), Run("dark", .italic), Run(".")]))],
            outline: [.paragraph(Paragraph("Mara arrives."))]
        )
        try package.write(chapter)
        try package.write(scene)

        var manifest = try package.load().manifest
        manifest.workingFile = "sc0001"
        try package.writeManifest(manifest)

        let loaded = try package.load()
        #expect(loaded.files == ["ch0001": chapter, "sc0001": scene])
        #expect(loaded.manifest.workingFile == "sc0001")
        #expect(loaded.tree.bookOrder == ["ch0001", "sc0001"])
        #expect(loaded.problems.isEmpty)
    }

    @Test func unchangedWriteLeavesFileAlone() throws {
        let package = try makePackage()
        let file = PemeriaFile(id: "abc123", title: "x", order: "V")
        try package.write(file)
        let url = package.fileURL(for: "abc123")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
        try package.write(file)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
        #expect(after == Date(timeIntervalSince1970: 0))
        #expect(before != after)
    }

    @Test func duplicatedFileGetsANewIDWithoutTouchingTheOriginal() throws {
        let package = try makePackage()
        let original = PemeriaFile(id: "abc123", title: "Original", order: "V")
        try package.write(original)
        // What Finder's "Duplicate" would produce.
        try FileManager.default.copyItem(
            at: package.fileURL(for: "abc123"),
            to: package.filesURL.appending(path: "abc123 copy.md")
        )

        let loaded = try package.load()
        #expect(loaded.files.count == 2)
        #expect(loaded.files["abc123"] == original)
        let copy = try #require(loaded.files.values.first { $0.id != "abc123" })
        #expect(copy.title == "Original")
        #expect(FileManager.default.fileExists(atPath: package.fileURL(for: copy.id).path))
        #expect(!FileManager.default.fileExists(atPath: package.filesURL.appending(path: "abc123 copy.md").path))
        #expect(loaded.problems.count == 1)

        // Repairs are on disk, so the next load is clean.
        #expect(try package.load().problems.isEmpty)
    }

    @Test func unreadableFileIsLeftUntouched() throws {
        let package = try makePackage()
        let bad = package.filesURL.appending(path: "bad001.md")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: bad)
        let loaded = try package.load()
        #expect(loaded.files.isEmpty)
        #expect(loaded.problems.count == 1)
        #expect(try Data(contentsOf: bad) == Data([0xFF, 0xFE, 0x00, 0xC3]))
    }

    @Test func missingManifestIsRecreated() throws {
        let package = try makePackage()
        try FileManager.default.removeItem(at: package.manifestURL)
        let loaded = try package.load()
        #expect(loaded.manifest.name == "Novel")
        #expect(loaded.problems.count == 1)
        #expect(FileManager.default.fileExists(atPath: package.manifestURL.path))
    }

    @Test func trashAndSnapshotsKeepCopies() throws {
        let package = try makePackage()
        var file = PemeriaFile(id: "abc123", title: "Draft", order: "V", body: [.paragraph(Paragraph("v1"))])
        try package.write(file)
        try package.snapshot("abc123", date: Date(timeIntervalSince1970: 0))
        file.body = [.paragraph(Paragraph("v2"))]
        try package.write(file)
        try package.snapshot("abc123", date: Date(timeIntervalSince1970: 600))

        let snapshots = try package.snapshots(of: "abc123")
        #expect(snapshots.count == 2)
        let first = FileCodec.decode(try String(contentsOf: snapshots[0], encoding: .utf8), fallbackID: "zzzzzz")
        #expect(first.body == [.paragraph(Paragraph("v1"))])

        try package.moveToTrash("abc123")
        #expect(try package.load().files.isEmpty)
        let trashed = try FileManager.default.contentsOfDirectory(atPath: package.trashURL.path)
        #expect(trashed.count == 1)
        #expect(trashed[0].hasPrefix("abc123 "))
    }
}
