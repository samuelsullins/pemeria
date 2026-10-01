import AppKit
import PemeriaCore
import SwiftUI

/// App-wide settings (SPEC.md §5): never per document.
enum PreferenceKey {
    static let fontName = "editorFontName"
    static let fontSize = "editorFontSize"
    static let lineHeight = "editorLineHeight"
    static let indent = "editorIndent"
    static let width = "editorWidth"
    static let justified = "editorJustified"
    static let theme = "appTheme"
}

/// The editor's typography, read from Preferences.
struct EditorStyle: Equatable {
    var fontName: String
    var fontSize: Double
    /// Line height as a multiple of the font's natural line height.
    var lineHeight: Double
    /// First-line indent, in ems.
    var indent: Double
    /// Maximum width of the text column, in points.
    var width: Double
    var justified: Bool

    static let fontChoices: [(id: String, name: String)] = [
        ("system-serif", "New York"),
        ("Charter-Roman", "Charter"),
        ("IowanOldStyle-Roman", "Iowan Old Style"),
        ("Palatino-Roman", "Palatino"),
        ("Baskerville", "Baskerville"),
        ("Georgia", "Georgia"),
        ("TimesNewRomanPSMT", "Times New Roman"),
        ("system", "SF Pro"),
        ("HelveticaNeue", "Helvetica Neue"),
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.fontName: "system-serif",
            PreferenceKey.fontSize: 18.0,
            PreferenceKey.lineHeight: 1.45,
            PreferenceKey.indent: 1.5,
            PreferenceKey.width: 680.0,
            PreferenceKey.justified: true,
            PreferenceKey.theme: "system",
        ])
    }

    static func current() -> EditorStyle {
        let defaults = UserDefaults.standard
        return EditorStyle(
            fontName: defaults.string(forKey: PreferenceKey.fontName) ?? "system-serif",
            fontSize: defaults.double(forKey: PreferenceKey.fontSize),
            lineHeight: defaults.double(forKey: PreferenceKey.lineHeight),
            indent: defaults.double(forKey: PreferenceKey.indent),
            width: defaults.double(forKey: PreferenceKey.width),
            justified: defaults.bool(forKey: PreferenceKey.justified)
        )
    }

    func baseFont() -> NSFont {
        let size = CGFloat(fontSize)
        switch fontName {
        case "system":
            return .systemFont(ofSize: size)
        case "system-serif":
            let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
        default:
            return NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
        }
    }

    func font(for style: InlineStyle) -> NSFont {
        var font = baseFont()
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.contains(.italic) { traits.insert(.italic) }
        if style.contains(.bold) { traits.insert(.bold) }
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        if let styled = NSFont(descriptor: descriptor, size: font.pointSize),
           styled.fontDescriptor.symbolicTraits.isSuperset(of: traits) {
            return styled
        }
        // Some families only answer through the font manager.
        if style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        if style.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        return font
    }
}

enum Theme {
    static func apply() {
        switch UserDefaults.standard.string(forKey: PreferenceKey.theme) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

struct PreferencesView: View {
    @AppStorage(PreferenceKey.fontName) private var fontName = "system-serif"
    @AppStorage(PreferenceKey.fontSize) private var fontSize = 18.0
    @AppStorage(PreferenceKey.lineHeight) private var lineHeight = 1.45
    @AppStorage(PreferenceKey.indent) private var indent = 1.5
    @AppStorage(PreferenceKey.width) private var width = 680.0
    @AppStorage(PreferenceKey.justified) private var justified = true
    @AppStorage(PreferenceKey.theme) private var theme = "system"

    var body: some View {
        Form {
            Section("Text") {
                Picker("Font", selection: $fontName) {
                    ForEach(EditorStyle.fontChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                Stepper("Size: \(Int(fontSize)) pt", value: $fontSize, in: 11...36, step: 1)
                Picker("Alignment", selection: $justified) {
                    Text("Justified").tag(true)
                    Text("Left").tag(false)
                }
                .pickerStyle(.segmented)
                LabeledContent("Line height") {
                    Slider(value: $lineHeight, in: 1.0...2.2, step: 0.05)
                    Text(lineHeight, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                LabeledContent("First-line indent") {
                    Slider(value: $indent, in: 0...4, step: 0.25)
                    Text("\(indent, format: .number.precision(.fractionLength(2))) em")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                LabeledContent("Text width") {
                    Slider(value: $width, in: 420...1100, step: 20)
                    Text("\(Int(width)) pt")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
