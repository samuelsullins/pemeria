import Testing
@testable import PemeriaCore

struct OrderKeyTests {
    @Test func firstKeyIsTheMiddle() {
        #expect(OrderKey.between(nil, nil) == "V")
    }

    @Test func rejectsBadInput() {
        #expect(OrderKey.between("b", "a") == nil)
        #expect(OrderKey.between("a", "a") == nil)
        #expect(OrderKey.between("a0", nil) == nil)
        #expect(OrderKey.between("a b", nil) == nil)
        #expect(OrderKey.between(nil, "") == nil)
    }

    @Test func appendingAndPrependingStaySorted() {
        let appended = OrderKey.sequence(count: 500)!
        #expect(appended == appended.sorted())
        #expect(Set(appended).count == appended.count)

        var first = "V"
        for _ in 0..<500 {
            let next = OrderKey.between(nil, first)!
            #expect(next < first)
            #expect(OrderKey.isValid(next))
            first = next
        }
    }

    @Test func randomInsertionsAlwaysFitBetween() {
        var rng = SeededGenerator(seed: 5)
        var keys = ["V"]
        for _ in 0..<3_000 {
            let slot = Int.random(in: 0...keys.count, using: &rng)
            let before = slot > 0 ? keys[slot - 1] : nil
            let after = slot < keys.count ? keys[slot] : nil
            let key = OrderKey.between(before, after)!
            #expect(OrderKey.isValid(key))
            if let before { #expect(before < key) }
            if let after { #expect(key < after) }
            keys.insert(key, at: slot)
        }
        #expect(keys == keys.sorted())
    }
}
