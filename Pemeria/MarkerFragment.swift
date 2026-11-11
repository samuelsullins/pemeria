import AppKit
import PemeriaCore

/// Draws a marker line (file header or outline divider) in place of its invisible character.
final class MarkerFragment: NSTextLayoutFragment {
    enum Kind {
        /// `copied` swaps the copy icon for a checkmark just after a copy. With no `title`, the
        /// header is a rule with the copy icon at its end (the file's title line follows it).
        case fileHeader(fileID: FileID, title: String?, copied: Bool)
        case outlineDivider
    }

    let kind: Kind

    init(textElement: NSTextElement, range: NSTextRange?, kind: Kind) {
        self.kind = kind
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The divider's pin button at the right end: "Pin Open", then its shortcut.
    private static let pinLabel = NSAttributedString(string: "Pin Open", attributes: [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.secondaryLabelColor,
    ])
    private static let pinKeys = NSAttributedString(string: "⌥⌘O", attributes: [
        .font: NSFont(descriptor: NSFont.systemFont(ofSize: 10, weight: .medium).fontDescriptor.withDesign(.rounded)
            ?? NSFont.systemFont(ofSize: 10).fontDescriptor, size: 10) ?? NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor.tertiaryLabelColor,
    ])

    private struct PinButton {
        var label: CGPoint
        var chip: CGRect
        var keys: CGPoint
        var whole: CGRect
    }

    /// Where each part of the pin button sits, relative to this fragment's origin.
    private var pinButton: PinButton {
        let labelSize = Self.pinLabel.size()
        let keysSize = Self.pinKeys.size()
        let chip = CGSize(width: ceil(keysSize.width) + 8, height: ceil(keysSize.height) + 2)
        let total = ceil(labelSize.width) + 6 + chip.width
        let midY = layoutFragmentFrame.height / 2
        var x = padding + lineWidth - total
        let start = x
        let label = CGPoint(x: x, y: midY - labelSize.height / 2)
        x += ceil(labelSize.width) + 6
        let chipRect = CGRect(x: x, y: midY - chip.height / 2, width: chip.width, height: chip.height)
        let keys = CGPoint(x: x + 4, y: midY - keysSize.height / 2)
        let height = max(chip.height, labelSize.height)
        return PinButton(label: label, chip: chipRect, keys: keys,
                         whole: CGRect(x: start, y: midY - height / 2, width: total, height: height))
    }

    /// The whole pin button, for clicks, relative to this fragment's origin.
    var pinRect: CGRect { pinButton.whole }

    /// Where a file header's copy icon sits: at the right end, on the title's line, or on the
    /// rule when there's no title.
    var copyRect: CGRect {
        let size: CGFloat = 14
        if case .fileHeader(_, nil, _) = kind {
            return CGRect(x: padding + lineWidth - size, y: layoutFragmentFrame.height / 2 - size / 2, width: size, height: size)
        }
        let lineY = layoutFragmentFrame.height * 0.35
        return CGRect(x: padding + lineWidth - size, y: lineY + 6, width: size, height: size)
    }

    /// The clickable icon on this line: the pin on a divider, the copy icon on a header.
    var buttonRect: CGRect? {
        switch kind {
        case .outlineDivider: pinRect
        case .fileHeader: hasCopyButton ? copyRect : nil
        }
    }

    /// Headers in the pinned outline pane are labels only.
    var hasCopyButton = true
    /// The dashed rule across a file header; left out where only outlines are shown.
    var hasRule = true

    private var lineWidth: CGFloat {
        let container = textLayoutManager?.textContainer
        return (container?.size.width ?? layoutFragmentFrame.width) - 2 * (container?.lineFragmentPadding ?? 0)
    }

    private var padding: CGFloat {
        textLayoutManager?.textContainer?.lineFragmentPadding ?? 0
    }

    override var renderingSurfaceBounds: CGRect {
        CGRect(x: 0, y: 0, width: lineWidth + 2 * padding, height: layoutFragmentFrame.height)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // TextKit can draw this outside the text view's own drawing, where the system colours
        // below would resolve against some other appearance: a dark one turned these gray file
        // names white on a light page. So draw in the text view's appearance, always.
        let appearance = textLayoutManager?.textContainer?.textView?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            drawMarker(at: point, in: context)
        }
    }

    private func drawMarker(at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let left = point.x + padding
        let right = left + lineWidth
        let height = layoutFragmentFrame.height

        switch kind {
        case .fileHeader(_, let title, let copied):
            if let title {
                let lineY = point.y + height * 0.35
                if hasRule { dashedLine(from: left, to: right, y: lineY, color: .tertiaryLabelColor, dash: [2, 5]) }
                let label = NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                label.draw(at: CGPoint(x: left, y: lineY + 6))
            } else if hasRule {
                // The rule stops short of the copy icon at its end.
                let end = hasCopyButton ? copyRect.minX + point.x - 10 : right
                dashedLine(from: left, to: end, y: point.y + height / 2, color: .tertiaryLabelColor, dash: [2, 5])
            }
            if hasCopyButton {
                let color: NSColor = copied ? Theme.accent : .tertiaryLabelColor
                let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                    .applying(.init(hierarchicalColor: color))
                if let image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: "Copy draft text")?
                    .withSymbolConfiguration(configuration) {
                    let box = copyRect.offsetBy(dx: point.x, dy: point.y)
                    let scale = min(box.width / image.size.width, box.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
                }
            }

        case .outlineDivider:
            // Headed like every section heading in the app (Documents, Comments, Labels…).
            let label = NSAttributedString(string: "Outline", attributes: [
                .font: NSFont.preferredFont(forTextStyle: .headline),
                .foregroundColor: NSColor.labelColor,
            ])
            let size = label.size()
            let midY = point.y + height / 2
            label.draw(at: CGPoint(x: left, y: midY - size.height / 2))
            let button = pinButton
            let shift = CGAffineTransform(translationX: point.x, y: point.y)
            let ruleStart = left + size.width + 10
            let ruleEnd = button.whole.applying(shift).minX - 10
            if ruleEnd > ruleStart {
                let rule = NSBezierPath()
                rule.move(to: CGPoint(x: ruleStart, y: midY))
                rule.line(to: CGPoint(x: ruleEnd, y: midY))
                rule.lineWidth = 0.5
                NSColor.separatorColor.setStroke()
                rule.stroke()
            }
            Self.pinLabel.draw(at: button.label.applying(shift))
            let chip = NSBezierPath(roundedRect: button.chip.applying(shift), xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            chip.fill()
            NSColor.labelColor.withAlphaComponent(0.1).setStroke()
            chip.lineWidth = 0.5
            chip.stroke()
            Self.pinKeys.draw(at: button.keys.applying(shift))
        }
    }

    private func dashedLine(from x1: CGFloat, to x2: CGFloat, y: CGFloat, color: NSColor, dash: [CGFloat]) {
        guard x2 > x1 else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x1, y: y))
        path.line(to: CGPoint(x: x2, y: y))
        path.lineWidth = 1
        path.setLineDash(dash, count: dash.count, phase: 0)
        color.setStroke()
        path.stroke()
    }
}
