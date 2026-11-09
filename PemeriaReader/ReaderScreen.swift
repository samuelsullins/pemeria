import PemeriaCore
import SwiftUI
import UIKit

/// Reads one file and everything nested in it, as one continuous text.
struct ReaderScreen: View {
    let library: Library
    let projectID: UUID
    let fileID: FileID
    @AppStorage("readMode") private var readMode = false
    @AppStorage("readerTextSize") private var textSize = 18.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let reader = library.reader(for: projectID), let project = reader.project {
            if let file = project.files[fileID] {
                let files = ([fileID] + project.descendants(of: fileID)).compactMap { project.files[$0] }
                let words = files.reduce(0) { $0 + (reader.bodyWords[$1.id] ?? 0) }
                ReaderTextView(
                    input: ReaderText.Input(files: files, icons: project.manifest.icons, readMode: readMode, fontSize: fontSize),
                    positionKey: "\(projectID.uuidString)/\(fileID.rawValue)"
                )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(file.title)
                .navigationSubtitle("\(words.formatted()) words")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
            } else {
                ContentUnavailableView("File Removed", systemImage: "doc.questionmark",
                                       description: Text("This file isn’t in the project any more."))
            }
        } else if let reader = library.reader(for: projectID) {
            ProjectStatusView(status: reader.status)
        } else {
            ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
        }
    }

    /// The chosen size, scaled with the system's text size.
    private var fontSize: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: textSize, compatibleWith: traits)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Text Size", systemImage: "textformat.size") {
                ControlGroup {
                    Button("Smaller", systemImage: "textformat.size.smaller") { textSize = max(12, textSize - 1) }
                        .disabled(textSize <= 12)
                    Button("Larger", systemImage: "textformat.size.larger") { textSize = min(32, textSize + 1) }
                        .disabled(textSize >= 32)
                }
                .controlGroupStyle(.compactMenu)
            }
            .menuActionDismissBehavior(.disabled)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle("Read Mode", systemImage: readMode ? "book.fill" : "book", isOn: $readMode)
                .help("Hide comments, bookmarks and outlines")
        }
    }
}

/// A non-editable text view for reading: selectable for copying, and it remembers where you
/// were in each file.
struct ReaderTextView: UIViewRepresentable {
    let input: ReaderText.Input
    let positionKey: String

    func makeUIView(context: Context) -> ReadingTextView {
        let view = ReadingTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.alwaysBounceVertical = true
        view.backgroundColor = .systemBackground
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: ReadingTextView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.positionKey != positionKey {
            coordinator.positionKey = positionKey
            coordinator.shown = nil
        }
        guard coordinator.shown != input else { return }
        // Keep your place: across a live update from the Mac, or where you left off last time.
        let offset = coordinator.shown == nil ? ReadingPositions.load(positionKey) : view.topCharacterOffset()
        coordinator.shown = input
        view.attributedText = ReaderText.build(input)
        view.scroll(toCharacterOffset: offset)
    }

    static func dismantleUIView(_ view: ReadingTextView, coordinator: Coordinator) {
        coordinator.savePosition(of: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var shown: ReaderText.Input?
        var positionKey = ""

        func savePosition(of view: ReadingTextView) {
            guard !positionKey.isEmpty, shown != nil else { return }
            ReadingPositions.save(view.topCharacterOffset(), for: positionKey)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate, let view = scrollView as? ReadingTextView { savePosition(of: view) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if let view = scrollView as? ReadingTextView { savePosition(of: view) }
        }
    }
}

/// Keeps the text in a comfortable column on wide screens, and scrolls by character offset so
/// a position survives text size changes and edits elsewhere in the file.
final class ReadingTextView: UITextView {
    static let maxColumnWidth: CGFloat = 640
    private var pendingOffset: Int?

    override func layoutSubviews() {
        let side = max(20, (bounds.width - Self.maxColumnWidth) / 2)
        let inset = UIEdgeInsets(top: 20, left: side, bottom: 60, right: side)
        if textContainerInset != inset { textContainerInset = inset }
        super.layoutSubviews()
        if let offset = pendingOffset, bounds.width > 0 {
            pendingOffset = nil
            DispatchQueue.main.async { self.scroll(toCharacterOffset: offset) }
        }
    }

    /// The first character on the top line showing.
    func topCharacterOffset() -> Int {
        let point = CGPoint(x: textContainerInset.left + 1, y: contentOffset.y + adjustedContentInset.top + 2)
        guard let position = closestPosition(to: point) else { return 0 }
        return offset(from: beginningOfDocument, to: position)
    }

    func scroll(toCharacterOffset offset: Int) {
        guard bounds.width > 0 else {
            pendingOffset = offset
            return
        }
        let top = -adjustedContentInset.top
        guard offset > 0, let position = position(from: beginningOfDocument, offset: min(offset, textStorage.length)) else {
            setContentOffset(CGPoint(x: 0, y: top), animated: false)
            return
        }
        if let layout = textLayoutManager,
           let end = layout.location(layout.documentRange.location, offsetBy: offset),
           let range = NSTextRange(location: layout.documentRange.location, end: end) {
            layout.ensureLayout(for: range)
        }
        let y = caretRect(for: position).minY - adjustedContentInset.top - 2
        let bottom = max(top, contentSize.height - bounds.height + adjustedContentInset.bottom)
        setContentOffset(CGPoint(x: 0, y: min(max(y, top), bottom)), animated: false)
    }
}

/// Where you were in each file, as a character offset, kept on this device only.
enum ReadingPositions {
    private static let key = "readingPositions"

    static func load(_ positionKey: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: key)?[positionKey] as? Int) ?? 0
    }

    static func save(_ offset: Int, for positionKey: String) {
        var positions = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        positions[positionKey] = offset
        UserDefaults.standard.set(positions, forKey: key)
    }
}
