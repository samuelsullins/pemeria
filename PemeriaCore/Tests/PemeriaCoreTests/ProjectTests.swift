import Foundation
import Testing
@testable import PemeriaCore

struct ProjectTests {
    /// ch1 [s11, s12], ch2 [s21], note
    func sample() -> Project {
        var project = Project(manifest: ProjectManifest(name: "Novel"), files: [:])
        let ch1 = project.createFile(kind: .draft, title: "Chapter 1")
        let ch2 = project.createFile(kind: .draft, title: "Chapter 2", after: ch1.id)
        _ = project.createFile(kind: .note, title: "Note", after: ch2.id)
        let s11 = project.createFile(kind: .draft, title: "s11")
        _ = project.move([s11.id], into: ch1.id, at: 0)
        let s12 = project.createFile(kind: .draft, title: "s12", after: s11.id)
        let s21 = project.createFile(kind: .draft, title: "s21")
        _ = project.move([s21.id], into: ch2.id, at: 0)
        _ = s12
        return project
    }

    func titles(_ project: Project, _ ids: [FileID]) -> [String] {
        ids.map { project.files[$0]!.title }
    }

    func id(_ project: Project, _ title: String) -> FileID {
        project.files.values.first { $0.title == title }!.id
    }

    @Test func createsInBookOrder() {
        let project = sample()
        #expect(titles(project, project.tree.bookOrder) == ["Chapter 1", "s11", "s12", "Chapter 2", "s21", "Note"])
        #expect(project.files[id(project, "Note")]!.kind == .note)
        #expect(project.files[id(project, "Note")]!.outline == nil)
        #expect(project.files[id(project, "s11")]!.outline == [])
    }

    @Test func newFileGoesRightAfterTheSelectedOne() {
        var project = sample()
        let file = project.createFile(kind: .draft, title: "new", after: id(project, "s11"))
        #expect(file.parent == id(project, "Chapter 1"))
        #expect(titles(project, project.children(of: file.parent)) == ["s11", "new", "s12"])
    }

    @Test func reorderWithinParentRewritesOnlyTheMovedFile() {
        var project = sample()
        let changed = project.move([id(project, "s12")], into: id(project, "Chapter 1"), at: 0)!
        #expect(changed.map(\.title) == ["s12"])
        #expect(titles(project, project.children(of: id(project, "Chapter 1"))) == ["s12", "s11"])
    }

    @Test func nestAndUnnest() {
        var project = sample()
        let note = id(project, "Note")
        _ = project.move([note], into: id(project, "s21"), at: 0)
        #expect(project.tree.parentOf[note] == id(project, "s21"))
        #expect(project.tree.depth(of: note) == 2)

        _ = project.move([note], into: nil, at: 0)
        #expect(titles(project, project.tree.roots) == ["Note", "Chapter 1", "Chapter 2"])
    }

    @Test func movingAParentBringsItsChildren() {
        var project = sample()
        _ = project.move([id(project, "Chapter 2")], into: nil, at: 0)
        #expect(titles(project, project.tree.bookOrder) == ["Chapter 2", "s21", "Chapter 1", "s11", "s12", "Note"])
    }

    @Test func multipleFilesMoveTogetherInBookOrder() {
        var project = sample()
        let moved = project.move([id(project, "Note"), id(project, "s11")], into: id(project, "Chapter 2"), at: 1)!
        #expect(Set(moved.map(\.title)) == ["Note", "s11"])
        #expect(titles(project, project.children(of: id(project, "Chapter 2"))) == ["s21", "s11", "Note"])
    }

    @Test func childOfASelectedParentIsNotMovedSeparately() {
        var project = sample()
        _ = project.move([id(project, "Chapter 1"), id(project, "s11")], into: nil, at: 3)
        #expect(project.tree.parentOf[id(project, "s11")] == id(project, "Chapter 1"))
        #expect(titles(project, project.tree.roots) == ["Chapter 2", "Note", "Chapter 1"])
    }

    @Test func cannotMoveIntoItselfOrItsChildren() {
        var project = sample()
        let ch1 = id(project, "Chapter 1")
        #expect(project.move([ch1], into: ch1, at: 0) == nil)
        #expect(project.move([ch1], into: id(project, "s11"), at: 0) == nil)
        #expect(!project.canMove([ch1], into: id(project, "s12")))
        #expect(project.canMove([ch1], into: id(project, "s21")))
    }

    @Test func brokenOrderKeysGetRenumbered() {
        var files: [FileID: PemeriaFile] = [:]
        for name in ["aaa", "bbb", "ccc"] {
            let id = FileID(name)!
            files[id] = PemeriaFile(id: id, title: name, order: "")
        }
        var project = Project(manifest: ProjectManifest(name: "x"), files: files)
        let changed = project.move(["ccc"], into: nil, at: 1)!
        #expect(changed.count == 3)
        #expect(titles(project, project.tree.roots) == ["aaa", "ccc", "bbb"])
        #expect(project.files.values.allSatisfy { OrderKey.isValid($0.order) })
    }

    @Test func renameIgnoresEmptyAndUnchangedTitles() {
        var project = sample()
        let s11 = id(project, "s11")
        #expect(project.rename(s11, to: "   ") == nil)
        #expect(project.rename(s11, to: "s11") == nil)
        #expect(project.rename(s11, to: "The\nStorm")?.title == "The Storm")
    }

    @Test func noteKeepsDraftOutline() {
        var project = sample()
        let s11 = id(project, "s11")
        _ = project.setKind([s11], to: .note)
        #expect(project.files[s11]!.outline == [])
        let note = id(project, "Note")
        _ = project.setKind([note], to: .draft)
        #expect(project.files[note]!.outline == [])
        #expect(project.setKind([note], to: .draft).isEmpty)
    }

    @Test func removingAParentRemovesItsChildren() {
        var project = sample()
        project.manifest.workingFile = id(project, "s12")
        let removed = project.remove([id(project, "Chapter 1")])
        #expect(removed.count == 3)
        #expect(titles(project, project.tree.bookOrder) == ["Chapter 2", "s21", "Note"])
        #expect(project.manifest.workingFile == nil)
    }

    @Test func randomMovesKeepEveryFileAndAValidTree() {
        var rng = SeededGenerator(seed: 6)
        var project = sample()
        for _ in 0..<20 { _ = project.createFile(kind: .draft, after: project.tree.bookOrder.randomElement(using: &rng)) }
        for _ in 0..<2_000 {
            let all = project.tree.bookOrder
            let ids = (0..<Int.random(in: 1...3, using: &rng)).map { _ in all.randomElement(using: &rng)! }
            let parent: FileID? = Bool.random(using: &rng) ? all.randomElement(using: &rng) : nil
            let index = Int.random(in: 0...project.children(of: parent).count, using: &rng)
            _ = project.move(ids, into: parent, at: index)
            #expect(Set(project.tree.bookOrder) == Set(project.files.keys))
            #expect(project.tree.bookOrder.count == project.files.count)
            // Stored parents should match the tree exactly: moves never create loops.
            #expect(project.files.values.allSatisfy { project.tree.parentOf[$0.id] == $0.parent })
        }
    }
}
