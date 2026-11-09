import PemeriaCore
import SwiftUI
import UIKit

extension IconDefinition {
    var uiColor: UIColor { UIColor(hex: color) ?? .secondaryLabel }
}

/// A file's icons, overlapping a little and fanned like cards, as in the Mac's sidebar.
struct IconFan: View {
    let icons: [IconDefinition]
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(icons.enumerated()), id: \.offset) { index, icon in
                Image(systemName: icon.symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color(uiColor: icon.uiColor))
                    .rotationEffect(.degrees(Self.angle(index, of: icons.count)))
                    .accessibilityLabel(icon.name)
            }
        }
    }

    static func angle(_ index: Int, of count: Int) -> Double {
        switch count {
        case 1: 0
        case 2: [-7, 7][index]
        default: [-10, 0, 10][min(index, 2)]
        }
    }
}

extension UIColor {
    /// "#RRGGBB" (or without the #).
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
