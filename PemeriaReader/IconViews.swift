import PemeriaCore
import SwiftUI
import UIKit

extension IconDefinition {
    var uiColor: UIColor { UIColor(hex: color) ?? .secondaryLabel }
}

/// A file's three label slots, drawn like the Mac's sidebar (SPEC.md §4): a square each, filled
/// with its label's colour and its symbol in white, or gray while empty. A label keeps its slot.
struct SlotSquares: View {
    let slots: [IconDefinition?]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(slots.indices, id: \.self) { slot in
                RoundedRectangle(cornerRadius: 4)
                    .fill(slots[slot].map { Color(uiColor: $0.uiColor) } ?? Color.primary.opacity(0.1))
                    .frame(width: 18, height: 18)
                    .overlay {
                        if let icon = slots[slot] {
                            Image(systemName: icon.symbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(slots.compactMap { $0?.name }.joined(separator: ", "))
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
