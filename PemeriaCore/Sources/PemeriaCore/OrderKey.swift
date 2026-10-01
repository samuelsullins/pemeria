/// Sortable position keys for siblings in the sidebar.
///
/// Keys are strings of base-62 digits that sort correctly with plain string comparison.
/// There's always room for a new key between any two others, so moving a file only
/// rewrites that one file. Keys never end in "0" (that would leave no room below them).
public enum OrderKey {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    public static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.last != "0" && key.allSatisfy { digits.contains($0) }
    }

    /// A key that sorts strictly between `before` and `after`.
    /// Pass nil for `before` to go first, nil for `after` to go last.
    /// Returns nil if either key is invalid or `before` doesn't sort below `after`.
    public static func between(_ before: String?, _ after: String?) -> String? {
        if let before, !isValid(before) { return nil }
        if let after {
            guard isValid(after) else { return nil }
            if let before, !(before < after) { return nil }
        }
        return midpoint(Array(before ?? ""), after.map(Array.init))
    }

    /// `count` keys in increasing order, all between `before` and `after`.
    public static func sequence(count: Int, between before: String? = nil, and after: String? = nil) -> [String]? {
        var keys: [String] = []
        var previous = before
        for _ in 0..<count {
            guard let key = between(previous, after) else { return nil }
            keys.append(key)
            previous = key
        }
        return keys
    }

    // Fractional midpoint: `a` may be empty (meaning "before everything"), `b` nil means
    // "after everything". Neither has trailing zeros, and a < b.
    private static func midpoint(_ a: [Character], _ b: [Character]?) -> String {
        if let b {
            var n = 0
            while n < b.count, (n < a.count ? a[n] : "0") == b[n] { n += 1 }
            if n > 0 {
                return String(b[0..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first.map(index(of:)) ?? 0
        let digitB = b?.first.map(index(of:)) ?? digits.count
        if digitB - digitA > 1 {
            return String(digits[(digitA + digitB + 1) / 2])
        }
        if let b, b.count > 1 {
            return String(b[0])
        }
        return String(digits[digitA]) + midpoint(Array(a.dropFirst()), nil)
    }

    private static func index(of digit: Character) -> Int {
        digits.firstIndex(of: digit)!
    }
}
