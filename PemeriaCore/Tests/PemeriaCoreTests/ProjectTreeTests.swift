import Testing
@testable import PemeriaCore

struct ProjectTreeTests {
    func file(_ id: FileID, parent: FileID? = nil, order: String) -> PemeriaFile {
        PemeriaFile(id: id, title: id.rawValue, parent: parent, order: order)
    }

    @Test func buildsNestedBookOrder() {
        let tree = ProjectTree(files: [
            file("ch2", order: "b"),
            file("ch1", order: "a"),
            file("s12", parent: "ch1", order: "b"),
            file("s11", parent: "ch1", order: "a"),
            file("s21", parent: "ch2", order: "V"),
        ])
        #expect(tree.roots == ["ch1", "ch2"])
        #expect(tree.children(of: "ch1") == ["s11", "s12"])
        #expect(tree.bookOrder == ["ch1", "s11", "s12", "ch2", "s21"])
        #expect(tree.depth(of: "s12") == 1)
        #expect(tree.depth(of: "ch2") == 0)
    }

    @Test func missingParentGoesToTopLevel() {
        let tree = ProjectTree(files: [file("orphan", parent: "gone", order: "V")])
        #expect(tree.roots == ["orphan"])
    }

    @Test func selfParentGoesToTopLevel() {
        let tree = ProjectTree(files: [file("self1", parent: "self1", order: "V")])
        #expect(tree.roots == ["self1"])
    }

    @Test func parentLoopIsBrokenWithoutLosingFiles() {
        let tree = ProjectTree(files: [
            file("aaa", parent: "ccc", order: "V"),
            file("bbb", parent: "aaa", order: "V"),
            file("ccc", parent: "bbb", order: "V"),
            file("tail", parent: "bbb", order: "W"),
        ])
        #expect(tree.roots == ["aaa"])
        #expect(Set(tree.bookOrder) == ["aaa", "bbb", "ccc", "tail"])
        #expect(tree.bookOrder.count == 4)
    }

    @Test func equalOrderKeysFallBackToID() {
        let tree = ProjectTree(files: [file("bbb", order: "V"), file("aaa", order: "V")])
        #expect(tree.roots == ["aaa", "bbb"])
    }
}
