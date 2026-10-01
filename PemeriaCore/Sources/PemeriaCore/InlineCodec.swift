/// Converts one paragraph to and from its line in the file.
///
/// The grammar is deliberately tiny so the two directions are exact inverses:
/// - `**` toggles bold, `*` toggles italic. A run of stars is read greedily as
///   bold toggles first, then at most one italic toggle (`***` = both).
/// - A backslash makes the next character literal. The writer escapes `\`, `*`, and
///   the `<` of any `<!--`, so prose can never be mistaken for formatting or markers.
///
/// Both directions work on Unicode scalars, so combining accents next to a `*` or `\`
/// can't change how the line is read.
public enum InlineCodec {
    public static func encode(_ paragraph: Paragraph) -> String {
        var line = String.UnicodeScalarView()
        var current: InlineStyle = []
        for run in paragraph.normalized().runs {
            line.append(contentsOf: toggles(from: current, to: run.style).unicodeScalars)
            escape(run.text, into: &line)
            current = run.style
        }
        line.append(contentsOf: toggles(from: current, to: []).unicodeScalars)
        return String(line)
    }

    public static func decode(_ line: String) -> Paragraph {
        let scalars = Array(line.unicodeScalars)
        var runs: [Run] = []
        var style: InlineStyle = []

        func append(_ scalar: Unicode.Scalar) {
            if let last = runs.indices.last, runs[last].style == style {
                runs[last].text.unicodeScalars.append(scalar)
            } else {
                runs.append(Run(String(scalar), style))
            }
        }

        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\\" {
                if i + 1 < scalars.count {
                    append(scalars[i + 1])
                    i += 2
                } else {
                    append(scalar)
                    i += 1
                }
            } else if scalar == "*" {
                var count = 0
                while i + count < scalars.count, scalars[i + count] == "*" { count += 1 }
                if (count / 2) % 2 == 1 { style.formSymmetricDifference(.bold) }
                if count % 2 == 1 { style.formSymmetricDifference(.italic) }
                i += count
            } else {
                append(scalar)
                i += 1
            }
        }
        return Paragraph(runs: runs).normalized()
    }

    // Toggles commute, but bold is always written first so the reader's greedy
    // `**`-then-`*` rule sees exactly what was written.
    private static func toggles(from old: InlineStyle, to new: InlineStyle) -> String {
        let changed = old.symmetricDifference(new)
        return (changed.contains(.bold) ? "**" : "") + (changed.contains(.italic) ? "*" : "")
    }

    private static func escape(_ text: String, into line: inout String.UnicodeScalarView) {
        let scalars = Array(text.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            if scalar == "\\" || scalar == "*" {
                line.append("\\")
            } else if scalar == "<", scalars[(i + 1)...].starts(with: ["!", "-", "-"]) {
                line.append("\\")
            }
            line.append(scalar)
        }
    }
}
