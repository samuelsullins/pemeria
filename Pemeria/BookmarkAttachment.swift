import AppKit
import PemeriaCore

/// A bookmark shown inline at its exact spot in the text: a small accent tag with the
/// bookmark's name and an × that deletes it (SPEC.md §7).
final class BookmarkAttachment: NSTextAttachment {
    let bookmark: Bookmark
    /// Called with the bookmark's id when its × is clicked.
    var onDelete: ((String) -> Void)?

    nonisolated static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    nonisolated static let height: CGFloat = 18

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    nonisolated var displayName: String {
        let name = bookmark.name.isEmpty ? "Bookmark" : bookmark.name
        return name.count > 24 ? String(name.prefix(23)) + "…" : name
    }

    /// Icon, name and × with padding.
    nonisolated var chipWidth: CGFloat {
        let nameWidth = (displayName as NSString).size(withAttributes: [.font: Self.nameFont]).width
        return ceil(7 + 10 + 4 + nameWidth + 5 + 12 + 5)
    }

    nonisolated override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        // A little room either side; sits on the line roughly centered on lowercase letters.
        CGRect(x: 0, y: -4, width: chipWidth + 6, height: Self.height)
    }

    nonisolated override func viewProvider(
        for parentView: NSView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        // TextKit asks for views while drawing, on the main thread.
        nonisolated(unsafe) var provider: BookmarkChipProvider?
        MainActor.assumeIsolated {
            provider = BookmarkChipProvider(
                textAttachment: self,
                parentView: parentView,
                textLayoutManager: textContainer?.textLayoutManager,
                location: location
            )
            provider?.tracksTextAttachmentViewBounds = true
        }
        return provider
    }
}

final class BookmarkChipProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? BookmarkAttachment else { return }
        view = BookmarkChipView(attachment: attachment)
    }
}

final class BookmarkChipView: NSView {
    private weak var attachment: BookmarkAttachment?
    private let label: NSTextField
    private let deleteButton: NSButton

    init(attachment: BookmarkAttachment) {
        self.attachment = attachment
        label = NSTextField(labelWithString: attachment.displayName)
        deleteButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Delete bookmark")!
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))!,
            target: nil,
            action: nil
        )
        super.init(frame: NSRect(x: 0, y: 0, width: attachment.chipWidth + 6, height: BookmarkAttachment.height))

        label.font = BookmarkAttachment.nameFont
        label.textColor = .controlAccentColor
        label.lineBreakMode = .byTruncatingTail
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .controlAccentColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = "Delete bookmark"

        let icon = NSImageView(image: NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!)
        icon.contentTintColor = .controlAccentColor

        for view in [icon, label, deleteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 3),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 14),
            deleteButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        toolTip = attachment.bookmark.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 3, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    }

    @objc private func deleteClicked() {
        guard let attachment else { return }
        attachment.onDelete?(attachment.bookmark.id)
    }
}
