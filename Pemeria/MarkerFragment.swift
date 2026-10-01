import AppKit

/// Draws a marker line (file header, outline divider, bookmark) in place of its invisible character.
final class MarkerFragment: NSTextLayoutFragment {
    enum Kind {
        case fileHeader(title: String)
        case outlineDivider
        case bookmark(name: String)
    }

    let kind: Kind

    init(textElement: NSTextElement, range: NSTextRange?, kind: Kind) {
        self.kind = kind
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Where the divider's pin icon sits, relative to this fragment's origin.
    var pinRect: CGRect {
        let size: CGFloat = 14
        return CGRect(x: padding + lineWidth - size, y: (layoutFragmentFrame.height - size) / 2, width: size, height: size)
    }

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
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let left = point.x + padding
        let right = left + lineWidth
        let height = layoutFragmentFrame.height

        switch kind {
        case .fileHeader(let title):
            let lineY = point.y + height * 0.35
            dashedLine(from: left, to: right, y: lineY, color: .tertiaryLabelColor, dash: [2, 5])
            let label = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            label.draw(at: CGPoint(x: left, y: lineY + 6))

        case .outlineDivider:
            let label = NSAttributedString(string: "OUTLINE", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.2,
            ])
            let size = label.size()
            let midY = point.y + height / 2
            label.draw(at: CGPoint(x: left, y: midY - size.height / 2))
            let pin = pinRect.offsetBy(dx: point.x, dy: point.y)
            let rule = NSBezierPath()
            rule.move(to: CGPoint(x: left + size.width + 10, y: midY))
            rule.line(to: CGPoint(x: pin.minX - 10, y: midY))
            rule.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            rule.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(.init(hierarchicalColor: .tertiaryLabelColor))
            if let image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin outline")?
                .withSymbolConfiguration(configuration) {
                image.draw(in: pin)
            }

        case .bookmark(let name):
            let midY = point.y + height / 2
            let label = NSAttributedString(string: name.isEmpty ? "Bookmark" : name, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor,
            ])
            let size = label.size()
            let pill = CGRect(x: left, y: midY - size.height / 2 - 2, width: size.width + 14, height: size.height + 4)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 2))
            dashedLine(from: pill.maxX + 6, to: right, y: midY, color: NSColor.controlAccentColor.withAlphaComponent(0.6), dash: [3, 3])
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
