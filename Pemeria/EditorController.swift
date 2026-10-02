import AppKit
import PemeriaCore

/// Runs the editor (SPEC.md §5): shows the selected files as one text, keeps every edit
/// inside one file, styles the text for display, and saves.
///
/// The text storage holds only meaning: the words, `.pemeriaStyle` for italic/bold, and
/// marker attributes. Fonts, indents and colors are added on the way to the screen
/// (`textContentStorage(_:textParagraphWith:)`), so Preferences changes never touch the text.
final class EditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate,
    NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {

    let textView: EditorTextView
    let scrollView = NSScrollView()

    private weak var model: ProjectModel?
    private(set) var mode: EditorMode
    /// Which split-view pane this editor belongs to (0 when not split).
    let pane: Int
    private(set) var shown: [ShownFile] = []
    private var segments: [EditorSegment] = []
    private var markers: [EditorMarker] = []
    private var pieces: [EditorContent.Piece] = []
    /// The model's `contentToken` when this text was loaded; a newer one means reload.
    private var loadedToken = -1
    private var handledJumpID = -1
    private var handledFocusRequest: Int?
    /// Files whose header copy icon is showing a checkmark for a moment.
    private var recentlyCopied: Set<FileID> = []
    /// True while removing a bookmark on purpose, so the step-over-bookmarks rule lets it through.
    private var isDeletingBookmark = false
    private var dirty: Set<FileID> = []
    private var saveTimer: Timer?
    /// True while replacing the whole text or refreshing display, so storage callbacks ignore it.
    private var isQuiet = false
    private var style = EditorStyle.current()
    private var fontCache: [UInt8: NSFont] = [:]
    private var observers: [NSObjectProtocol] = []

    /// The pinned outline pane doesn't take part in remembering your place; the main editor does.
    private var remembersPosition: Bool { mode == .full || mode == .bodies }
    /// Outlines are drawn quieter than the draft, except in Outline view where they're the point.
    private var dimsOutlines: Bool { mode != .outlineView }

    init(mode: EditorMode, pane: Int) {
        self.mode = mode
        self.pane = pane
        textView = EditorTextView(usingTextLayoutManager: true)
        super.init()

        textView.controller = self
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = UserDefaults.standard.bool(forKey: PreferenceKey.spellCheck)
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.25)]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.maxTextWidth = CGFloat(style.width)

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.textContentStorage?.delegate = self
        textView.textLayoutManager?.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        })
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.commit()
                self?.model?.saveState()
            }
        })
    }

    /// Call when the view goes away: saves, and stops listening.
    func detach() {
        commit()
        model?.setSelectedTextWords(nil, from: self, pane: pane)
        model?.unregisterEditor(self)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    // MARK: Showing files

    /// Brings the editor in line with the model: reloads if the shown files changed,
    /// otherwise just refreshes file-header titles.
    func sync(with model: ProjectModel, mode: EditorMode) {
        if self.model !== model {
            self.model?.unregisterEditor(self)
            self.model = model
            model.registerEditor(self) { [weak self] in self?.commit() }
        }

        let selected = Set(model.selection(forPane: pane))
        let files = model.project.tree.bookOrder.filter(selected.contains).compactMap { model.project.files[$0] }
        let key = files.map { ShownFile(id: $0.id, kind: $0.kind) }
        if key != shown || mode != self.mode || model.contentToken != loadedToken {
            self.mode = mode
            loadedToken = model.contentToken
            show(files)
        } else {
            refreshHeaderTitles(files)
        }
        handlePendingJump()
        handleFocusRequest(model.focusRequest)
    }

    private var isInActivePane: Bool {
        guard let model else { return false }
        return !model.isSplit || model.activePane == pane
    }

    /// Clicking into an editor makes its pane the active one.
    func didBecomeFirstResponder() {
        model?.activate(pane: pane)
    }

    /// The main editor takes keyboard focus when asked (e.g. after ⌘J).
    private func handleFocusRequest(_ request: Int) {
        defer { handledFocusRequest = request }
        guard let handled = handledFocusRequest, handled != request, mode != .outlines, isInActivePane else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textView.window?.makeFirstResponder(self.textView)
        }
    }

    private func show(_ files: [PemeriaFile]) {
        // Edits are normally saved before the selection changes; this is the safety net.
        if !dirty.isEmpty { commit(recordingPosition: false) }
        let content = EditorContent(files: files, mode: mode)
        isQuiet = true
        segments = content.segments
        markers = content.markers
        pieces = content.pieces
        textView.textStorage?.setAttributedString(content.text)
        isQuiet = false
        shown = files.map { ShownFile(id: $0.id, kind: $0.kind) }
        textView.isEditable = mode != .reading
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: segments.first?.range.location ?? 0, length: 0))
        resetTypingAttributes()
        DispatchQueue.main.async { [weak self] in self?.restorePosition() }
    }

    private func refreshHeaderTitles(_ files: [PemeriaFile]) {
        let titles = Dictionary(files.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for marker in markers where marker.kind == .fileHeader {
            guard let title = titles[marker.fileID], title != marker.title else { continue }
            marker.title = title
            if let range = range(of: marker) { refreshDisplay(in: range) }
        }
    }

    private func range(of marker: EditorMarker) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.pemeriaMarker, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? EditorMarker) === marker {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: Keeping edits inside one file

    private func segmentIndex(containing range: NSRange) -> Int? {
        segments.firstIndex { $0.contains(range) }
    }

    var selectionIsInsideOneSegment: Bool {
        let ranges = textView.selectedRanges.map(\.rangeValue)
        guard let first = ranges.first, let index = segmentIndex(containing: first) else { return false }
        return ranges.allSatisfy { segments[index].contains($0) }
    }

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        if isQuiet { return true }
        let allowed = affectedRanges.allSatisfy { segmentIndex(containing: $0.rangeValue) != nil }
        if !allowed {
            flashBlocked()
            return false
        }
        // Backspace/Delete next to a bookmark deletes the character beyond it, not the bookmark:
        // bookmarks are only removed on purpose (from the margin popup or the panel).
        if !isDeletingBookmark, affectedRanges.count == 1, replacementStrings?.first == "",
           let beyond = deletionSteppingOverBookmarks(affectedRanges[0].rangeValue) {
            DispatchQueue.main.async { [weak self] in self?.delete(beyond) }
            return false
        }
        return true
    }

    private func isBookmark(at index: Int) -> Bool {
        guard let storage = textView.textStorage, index >= 0, index < storage.length else { return false }
        return storage.attribute(.pemeriaBookmark, at: index, effectiveRange: nil) != nil
    }

    /// For a one-character deletion that would hit only bookmark characters, the character
    /// just past them in the direction of the deletion (nil if the deletion is fine as it is).
    private func deletionSteppingOverBookmarks(_ range: NSRange) -> NSRange? {
        guard range.length >= 1, (range.location..<NSMaxRange(range)).allSatisfy(isBookmark(at:)),
              let segment = segments.first(where: { $0.contains(range) }) else { return nil }
        let cursor = textView.selectedRange().location
        let backward = cursor >= NSMaxRange(range)
        var index = backward ? range.location - 1 : NSMaxRange(range)
        while isBookmark(at: index) { index += backward ? -1 : 1 }
        let next = NSRange(location: index, length: 1)
        // Nothing left to delete in this file: do nothing (rather than remove the bookmark).
        return segment.contains(next) ? next : NSRange(location: NSNotFound, length: 0)
    }

    private func delete(_ range: NSRange) {
        guard range.location != NSNotFound, let storage = textView.textStorage,
              NSMaxRange(range) <= storage.length,
              textView.shouldChangeText(in: range, replacementString: "") else { return }
        storage.replaceCharacters(in: range, with: "")
        textView.didChangeText()
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !isQuiet else { return }
        let before = NSRange(location: editedRange.location, length: editedRange.length - delta)
        guard let index = segmentIndex(containing: before) else {
            // Shouldn't happen (edits outside a file are refused), but if it does, rebuild the
            // segment map from the marker lines rather than guess.
            DispatchQueue.main.async { [weak self] in self?.resyncSegments() }
            return
        }
        if editedMask.contains(.editedCharacters), delta != 0 {
            segments[index].range.length += delta
            for later in segments.indices where later > index {
                segments[later].range.location += delta
            }
        }
        markDirty(segments[index].fileID)

        // Whether a paragraph is the first in its file (and so not indented) can change when a
        // line break is typed or deleted near the top; refresh the opening paragraphs.
        if editedMask.contains(.editedCharacters) {
            let segment = segments[index]
            let string = textStorage.string as NSString
            let firstBreak = string.range(of: "\n", options: .literal, range: segment.range).location
            if firstBreak == NSNotFound || editedRange.location <= firstBreak {
                DispatchQueue.main.async { [weak self] in
                    guard let self, index < self.segments.count else { return }
                    let current = self.segments[index].range
                    let text = textStorage.string as NSString
                    let end = text.length
                    var stop = current.location
                    for _ in 0..<2 where stop < end {
                        let lineEnd = text.range(of: "\n", options: .literal, range: NSRange(location: stop, length: end - stop)).location
                        stop = lineEnd == NSNotFound ? end : lineEnd + 1
                    }
                    self.refreshDisplay(in: NSRange(location: current.location, length: min(stop, NSMaxRange(current)) - current.location))
                }
            }
        }
    }

    /// Rebuilds segment ranges from where the marker lines actually are, following the recorded
    /// layout: each marker ends the segment before it, and the next segment starts a line later.
    private func resyncSegments() {
        guard let storage = textView.textStorage else { return }
        var markerLocations: [Int] = []
        storage.enumerateAttribute(.pemeriaMarker, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { markerLocations.append(range.location) }
        }
        // Markers can't be edited, so this can't really differ; if it somehow does, keep the
        // current map rather than risk filing text under the wrong file.
        guard markerLocations.count == markers.count else { return }

        var rebuilt = segments
        var markerIndex = 0
        var start = 0
        for piece in pieces {
            switch piece {
            case .marker:
                start = markerLocations[markerIndex] + 2
                markerIndex += 1
            case .segment(let index):
                let end = markerIndex < markerLocations.count ? markerLocations[markerIndex] - 1 : storage.length
                rebuilt[index].range = NSRange(location: start, length: max(0, end - start))
            }
        }
        segments = rebuilt
    }

    /// Re-runs display styling for a range without changing the text.
    private func refreshDisplay(in range: NSRange) {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
        isQuiet = true
        storage.beginEditing()
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        storage.endEditing()
        isQuiet = false
    }

    private func flashBlocked() {
        let flash = NSView(frame: scrollView.contentView.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.08).cgColor
        flash.autoresizingMask = [.width, .height]
        scrollView.addSubview(flash)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            flash.animator().alphaValue = 0
        }, completionHandler: { flash.removeFromSuperview() })
    }

    // MARK: Moving around

    /// The header or divider character whose line contains `location`, if any.
    private func markerLine(at location: Int) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        let length = storage.length
        func isMarker(_ index: Int) -> Bool {
            guard index >= 0, index < length else { return false }
            return storage.attribute(.pemeriaMarker, at: index, effectiveRange: nil) != nil
        }
        if isMarker(location) { return NSRange(location: location, length: 1) }
        if isMarker(location - 1) { return NSRange(location: location - 1, length: 1) }
        return nil
    }

    /// The cursor never rests on a header or divider line; it hops over in the direction of travel.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldRange: NSRange, toCharacterRange newRange: NSRange) -> NSRange {
        guard !isQuiet, newRange.length == 0, markerLine(at: newRange.location) != nil,
              let length = textView.textStorage?.length else { return newRange }
        let forward = newRange.location >= oldRange.location
        // Step line by line (there may be several marker lines in a row) until clear of them.
        func hop(from location: Int, forward: Bool) -> Int? {
            var current = location
            for _ in 0..<64 {
                guard let marker = markerLine(at: current) else { return current }
                current = forward ? marker.location + 2 : marker.location - 1
                if current < 0 || current > length { return nil }
            }
            return nil
        }
        let target = hop(from: newRange.location, forward: forward) ?? hop(from: newRange.location, forward: !forward)
        return NSRange(location: target ?? newRange.location, length: 0)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        resetTypingAttributes()
        model?.setSelectedTextWords(selectedTextWordCount(), from: self, pane: pane)
    }

    /// Words in the selected text, leaving out comments and marker lines; nil with no selection.
    private func selectedTextWordCount() -> Int? {
        guard let storage = textView.textStorage else { return nil }
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return nil }
        let string = storage.string as NSString
        var total = 0
        for range in ranges {
            // Each paragraph the range touches, counted against the whole paragraph so comments are found.
            let previousBreak = string.range(of: "\n", options: [.literal, .backwards],
                                             range: NSRange(location: 0, length: range.location)).location
            var lineStart = previousBreak == NSNotFound ? 0 : previousBreak + 1
            while lineStart < NSMaxRange(range) {
                let newline = string.range(of: "\n", options: .literal,
                                           range: NSRange(location: lineStart, length: string.length - lineStart)).location
                let lineEnd = newline == NSNotFound ? string.length : newline
                let line = NSRange(location: lineStart, length: lineEnd - lineStart)
                let part = NSIntersectionRange(range, line)
                if part.length > 0 {
                    total += WordCount.count(in: NSRange(location: part.location - lineStart, length: part.length),
                                             ofLine: string.substring(with: line))
                }
                lineStart = lineEnd + 1
            }
        }
        return total
    }

    /// Typing attributes come from the character before the cursor; keep only italic/bold, and
    /// display attributes to match, so marker attributes never leak into typed text.
    private func resetTypingAttributes() {
        var attributes = textView.typingAttributes
        attributes[.pemeriaMarker] = nil
        attributes[.pemeriaBookmark] = nil
        let raw = (attributes[.pemeriaStyle] as? NSNumber)?.uint8Value ?? 0
        let location = textView.selectedRange().location
        let segment = segments.first { $0.contains(NSRange(location: location, length: 0)) }
        attributes[.font] = font(for: raw)
        attributes[.foregroundColor] = segment?.role == .outline && dimsOutlines ? NSColor.secondaryLabelColor : NSColor.textColor
        attributes[.paragraphStyle] = paragraphStyle(indented: segment?.isIndented ?? false)
        textView.typingAttributes = attributes
    }

    // MARK: Clicks on margin and marker icons

    /// Handles a click on a bookmark's margin icon, a divider's pin, or a file header's copy icon.
    /// Returns false for any other click.
    func handleClick(at point: NSPoint) -> Bool {
        guard let layout = textView.textLayoutManager else { return false }
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        // Look up the line by height alone: margin clicks are outside the text column.
        if let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: containerPoint.y)) as? BookmarkedParagraphFragment {
            let frameOrigin = fragment.layoutFragmentFrame.origin
            if let mark = fragment.marks().first(where: {
                $0.clickRect.offsetBy(dx: frameOrigin.x, dy: frameOrigin.y).insetBy(dx: -4, dy: -4).contains(containerPoint)
            }) {
                let icon = mark.iconRect.offsetBy(dx: frameOrigin.x + origin.x, dy: frameOrigin.y + origin.y)
                showBookmarkEditor(for: mark.bookmark, iconRect: icon)
                return true
            }
        }
        guard let fragment = layout.textLayoutFragment(for: containerPoint) as? MarkerFragment,
              let target = fragment.buttonRect?.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY),
              target.insetBy(dx: -6, dy: -6).contains(containerPoint) else { return false }
        switch fragment.kind {
        case .outlineDivider:
            model?.outlinePinned = true
        case .fileHeader(let fileID, _, _):
            copyDraftText(of: fileID)
        }
        return true
    }

    /// The copy icon on a file's header: copies that file's draft text, then shows a checkmark briefly.
    private func copyDraftText(of fileID: FileID) {
        model?.copyDraftText(of: [fileID])
        recentlyCopied.insert(fileID)
        refreshHeader(of: fileID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.recentlyCopied.remove(fileID)
            self?.refreshHeader(of: fileID)
        }
    }

    private func refreshHeader(of fileID: FileID) {
        guard let marker = markers.first(where: { $0.kind == .fileHeader && $0.fileID == fileID }),
              let range = range(of: marker) else { return }
        refreshDisplay(in: range)
    }

    // MARK: Bookmarks and comments

    /// ⌘D: asks for a name, then bookmarks the cursor's exact spot (SPEC.md §7).
    func beginAddingBookmark() {
        guard textView.isEditable, let storage = textView.textStorage else { NSSound.beep(); return }
        let location = textView.selectedRange().location
        guard segments.contains(where: { $0.contains(NSRange(location: location, length: 0)) }) else { NSSound.beep(); return }
        let string = storage.string as NSString
        let line = string.lineRange(for: NSRange(location: location, length: 0))
        // Words from the cursor on, for a name if none is typed.
        let following = string.substring(with: NSRange(location: location, length: NSMaxRange(line) - location))
        let fallback = following.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")

        var anchor = caretRect(at: location) ?? NSRect(x: textView.textContainerOrigin.x, y: textView.visibleRect.midY, width: 1, height: 20)
        anchor = anchor.intersection(textView.visibleRect).isNull ? NSRect(x: anchor.minX, y: textView.visibleRect.midY, width: 1, height: 20) : anchor
        // Open below the cursor, or above it when the cursor is in the lower half of the window.
        let edge: NSRectEdge = anchor.midY > textView.visibleRect.midY ? .minY : .maxY
        BookmarkNamePrompt.show(relativeTo: anchor, of: textView, preferredEdge: edge) { [weak self] name in
            guard let self else { return }
            self.insertBookmark(named: name.isEmpty ? (fallback.isEmpty ? "Bookmark" : fallback) : name, at: location)
            self.textView.window?.makeFirstResponder(self.textView)
        }
    }

    private func insertBookmark(named name: String, at location: Int) {
        guard let storage = textView.textStorage else { return }
        var taken = model?.project.bookmarkIDs ?? []
        storage.enumerateAttribute(.pemeriaBookmark, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let marker = value as? BookmarkMarker { taken.insert(marker.bookmark.id) }
        }
        let bookmark = Bookmark(id: Bookmark.generateID(avoiding: taken), name: name)
        let tag = TextBridge.marker(for: bookmark)
        let range = NSRange(location: location, length: 0)
        guard textView.shouldChangeText(in: range, replacementString: tag.string) else { return }
        storage.replaceCharacters(in: range, with: tag)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: location + 1, length: 0))
    }

    private func bookmarkRange(id: String) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.pemeriaBookmark, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as? BookmarkMarker)?.bookmark.id == id {
                found = NSRange(location: range.location, length: 1)
                stop.pointee = true
            }
        }
        return found
    }

    /// Removes a bookmark (undoable, like any edit).
    private func deleteBookmark(id: String) {
        isDeletingBookmark = true
        defer { isDeletingBookmark = false }
        guard textView.isEditable, let storage = textView.textStorage, let range = bookmarkRange(id: id),
              textView.shouldChangeText(in: range, replacementString: "") else { return }
        storage.replaceCharacters(in: range, with: "")
        textView.didChangeText()
    }

    /// Starts a `//` comment at the cursor.
    func insertComment() {
        guard textView.isEditable, let storage = textView.textStorage else { NSSound.beep(); return }
        let location = textView.selectedRange().location
        let string = storage.string as NSString
        let needsSpace = location > 0 && !(Character(UnicodeScalar(string.character(at: location - 1)) ?? " ").isWhitespace)
        textView.insertText(needsSpace ? " // " : "// ", replacementRange: textView.selectedRange())
    }

    /// Moves to a comment or bookmark chosen in the right panel, if it's in this editor.
    private func handlePendingJump() {
        guard let model, let request = model.jumpRequest, request.id != handledJumpID, isInActivePane else { return }
        let role: EditorSegment.Role = request.location.inOutline ? .outline : .body
        guard mode != .reading, segments.contains(where: { $0.fileID == request.location.fileID && $0.role == role }) else { return }
        handledJumpID = request.id
        // After any pending reload/position restore.
        DispatchQueue.main.async { [weak self] in
            self?.jump(to: request.location, bookmarkID: request.bookmarkID)
            if model.jumpRequest?.id == request.id { model.jumpRequest = nil }
        }
    }

    private func jump(to location: TextLocation, bookmarkID: String?) {
        let role: EditorSegment.Role = location.inOutline ? .outline : .body
        guard let storage = textView.textStorage,
              let segment = segments.first(where: { $0.fileID == location.fileID && $0.role == role }) else { return }
        let target: NSRange
        if let bookmarkID, let tag = bookmarkRange(id: bookmarkID) {
            target = NSRange(location: NSMaxRange(tag), length: 0)
        } else {
            let string = storage.string as NSString
            let end = NSMaxRange(segment.range)
            var lineStart = segment.range.location
            for _ in 0..<location.paragraph {
                let next = string.range(of: "\n", options: .literal, range: NSRange(location: lineStart, length: end - lineStart))
                guard next.location != NSNotFound else { break }
                lineStart = next.location + 1
            }
            // Offsets count the paragraph's own text; step over any bookmark characters.
            func position(_ offset: Int) -> Int {
                var index = lineStart
                var counted = 0
                while index < end, counted < offset, string.character(at: index) != 0x0A {
                    if storage.attribute(.pemeriaBookmark, at: index, effectiveRange: nil) == nil { counted += 1 }
                    index += 1
                }
                return index
            }
            let start = position(location.range.location)
            target = NSRange(location: start, length: position(NSMaxRange(location.range)) - start)
        }
        textView.setSelectedRange(NSRange(location: target.location, length: 0))
        if let rect = caretRect(at: target.location) {
            textView.scroll(NSPoint(x: 0, y: max(0, rect.minY - textView.visibleRect.height / 3)))
        }
        if target.length > 0 { textView.showFindIndicator(for: target) }
        textView.window?.makeFirstResponder(textView)
    }

    /// Clicking a margin icon: a popup with the full name ready to edit, and a Delete button.
    private func showBookmarkEditor(for bookmark: Bookmark, iconRect: CGRect) {
        guard textView.isEditable else { return }
        let edge: NSRectEdge = iconRect.midY > textView.visibleRect.midY ? .minY : .maxY
        BookmarkNamePrompt.show(
            relativeTo: iconRect,
            of: textView,
            preferredEdge: edge,
            initialName: bookmark.name,
            onDelete: { [weak self] in self?.deleteBookmark(id: bookmark.id) }
        ) { [weak self] name in
            guard let self, !name.isEmpty, name != bookmark.name, let storage = self.textView.textStorage,
                  let range = self.bookmarkRange(id: bookmark.id),
                  self.textView.shouldChangeText(in: range, replacementString: nil) else { return }
            var renamed = bookmark
            renamed.name = name
            storage.addAttribute(.pemeriaBookmark, value: BookmarkMarker(renamed), range: range)
            self.textView.didChangeText()
        }
    }

    // MARK: Italic and bold

    func toggle(_ trait: InlineStyle) {
        guard let storage = textView.textStorage else { return }
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }

        if ranges.isEmpty {
            var attributes = textView.typingAttributes
            var current = InlineStyle(rawValue: (attributes[.pemeriaStyle] as? NSNumber)?.uint8Value ?? 0)
            current.formSymmetricDifference(trait)
            attributes[.pemeriaStyle] = current.isEmpty ? nil : NSNumber(value: current.rawValue)
            attributes[.font] = font(for: current.rawValue)
            textView.typingAttributes = attributes
            return
        }

        var changes: [(NSRange, InlineStyle)] = []
        var everythingHasTrait = true
        for range in ranges {
            storage.enumerateAttribute(.pemeriaStyle, in: range) { value, subrange, _ in
                let existing = InlineStyle(rawValue: (value as? NSNumber)?.uint8Value ?? 0)
                if !existing.contains(trait) { everythingHasTrait = false }
                changes.append((subrange, existing))
            }
        }
        guard textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) else { return }
        storage.beginEditing()
        for (range, existing) in changes {
            var updated = existing
            if everythingHasTrait { updated.remove(trait) } else { updated.insert(trait) }
            if updated.isEmpty {
                storage.removeAttribute(.pemeriaStyle, range: range)
            } else {
                storage.addAttribute(.pemeriaStyle, value: NSNumber(value: updated.rawValue), range: range)
            }
        }
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: Clipboard

    /// Inserts pasted or dropped text, keeping only italic/bold and the characters themselves.
    func insertPasted(_ incoming: NSAttributedString) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let cleaned = NSMutableAttributedString(attributedString: incoming)
        for lineBreak in ["\r\n", "\r", "\u{2028}", "\u{2029}"] {
            cleaned.mutableString.replaceOccurrences(of: lineBreak, with: "\n", options: .literal,
                                                     range: NSRange(location: 0, length: cleaned.length))
        }
        for invisible in [String(TextBridge.markerCharacter), "\u{FFFC}"] {
            cleaned.mutableString.replaceOccurrences(of: invisible, with: "", options: .literal,
                                                     range: NSRange(location: 0, length: cleaned.length))
        }
        let result = NSMutableAttributedString(string: cleaned.string)
        cleaned.enumerateAttribute(.font, in: NSRange(location: 0, length: cleaned.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            var style: InlineStyle = []
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.italic) { style.insert(.italic) }
            if traits.contains(.bold) { style.insert(.bold) }
            if !style.isEmpty { result.addAttribute(.pemeriaStyle, value: NSNumber(value: style.rawValue), range: range) }
        }

        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: result.string) else { return false }
        storage.replaceCharacters(in: range, with: result)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location + result.length, length: 0))
        return true
    }

    /// The selection as it should leave the app: no marker lines or invisible characters,
    /// with real fonts so italics survive the trip into other apps.
    func cleanCopyOfSelection() -> NSAttributedString {
        guard let storage = textView.textStorage else { return NSAttributedString() }
        let copy = NSMutableAttributedString()
        for (index, value) in textView.selectedRanges.enumerated() {
            if index > 0 { copy.append(NSAttributedString(string: "\n")) }
            copy.append(storage.attributedSubstring(from: value.rangeValue))
        }

        // Remove bookmark tags, then divider lines (the marker character plus its line break), last first.
        var bookmarkRanges: [NSRange] = []
        copy.enumerateAttribute(.pemeriaBookmark, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value != nil { bookmarkRanges.append(range) }
        }
        for range in bookmarkRanges.reversed() { copy.deleteCharacters(in: range) }
        var markerRanges: [NSRange] = []
        copy.enumerateAttribute(.pemeriaMarker, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if value != nil { markerRanges.append(range) }
        }
        let string = copy.string as NSString
        for range in markerRanges.sorted(by: { $0.location > $1.location }) {
            var removal = range
            if NSMaxRange(range) < string.length, string.character(at: NSMaxRange(range)) == 10 {
                removal.length += 1
            } else if range.location > 0, string.character(at: range.location - 1) == 10 {
                removal = NSRange(location: range.location - 1, length: range.length + 1)
            }
            copy.deleteCharacters(in: removal)
        }
        for invisible in [TextBridge.markerCharacter, TextBridge.bookmarkCharacter] {
            copy.mutableString.replaceOccurrences(of: String(invisible), with: "", options: .literal,
                                                  range: NSRange(location: 0, length: copy.length))
        }

        let result = NSMutableAttributedString(string: copy.string, attributes: [.font: font(for: 0)])
        copy.enumerateAttribute(.pemeriaStyle, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if let raw = (value as? NSNumber)?.uint8Value { result.addAttribute(.font, value: font(for: raw), range: range) }
        }
        return result
    }

    // MARK: Display

    private func font(for raw: UInt8) -> NSFont {
        if let cached = fontCache[raw] { return cached }
        let font = style.font(for: InlineStyle(rawValue: raw))
        fontCache[raw] = font
        return font
    }

    private func paragraphStyle(indented: Bool) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(style.lineHeight)
        paragraph.firstLineHeadIndent = indented ? CGFloat(style.indent * style.fontSize) : 0
        paragraph.paragraphSpacing = 0
        paragraph.alignment = style.justified ? .justified : .natural
        return paragraph
    }

    private func markerParagraphStyle(height: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        return paragraph
    }

    func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = textContentStorage.textStorage, NSMaxRange(range) <= storage.length else { return nil }
        let display = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        let whole = NSRange(location: 0, length: display.length)

        if display.length > 0, let marker = display.attribute(.pemeriaMarker, at: 0, effectiveRange: nil) as? EditorMarker {
            let height: CGFloat = marker.kind == .fileHeader ? 64 : 44
            display.addAttributes([
                .paragraphStyle: markerParagraphStyle(height: height),
                .foregroundColor: NSColor.clear,
                .font: font(for: 0),
            ], range: whole)
            return NSTextParagraph(attributedString: display)
        }

        let segment = segments.first { $0.contains(NSRange(location: range.location, length: 0)) }
        let isFirst = segment.map { $0.range.location == range.location } ?? false
        let indented = (segment?.isIndented ?? false) && !isFirst
        display.addAttribute(.paragraphStyle, value: paragraphStyle(indented: indented), range: whole)
        display.addAttribute(.foregroundColor,
                             value: segment?.role == .outline && dimsOutlines ? NSColor.secondaryLabelColor : NSColor.textColor,
                             range: whole)
        display.addAttribute(.font, value: font(for: 0), range: whole)
        display.enumerateAttribute(.pemeriaStyle, in: whole) { value, subrange, _ in
            if let raw = (value as? NSNumber)?.uint8Value { display.addAttribute(.font, value: font(for: raw), range: subrange) }
        }
        let commentColor = segment?.role == .outline && dimsOutlines ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
        for comment in Comments.ranges(in: display.string) {
            display.addAttribute(.foregroundColor, value: commentColor, range: comment)
        }
        return NSTextParagraph(attributedString: display)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let line = paragraph.attributedString
            if let marker = line.attribute(.pemeriaMarker, at: 0, effectiveRange: nil) as? EditorMarker {
                let kind: MarkerFragment.Kind = switch marker.kind {
                case .fileHeader: .fileHeader(fileID: marker.fileID, title: marker.title, copied: recentlyCopied.contains(marker.fileID))
                case .outlineDivider: .outlineDivider
                }
                let fragment = MarkerFragment(textElement: textElement, range: textElement.elementRange, kind: kind)
                fragment.hasCopyButton = mode != .outlines && mode != .outlineView
                return fragment
            }
            var bookmarks: [(index: Int, bookmark: Bookmark)] = []
            line.enumerateAttribute(.pemeriaBookmark, in: NSRange(location: 0, length: line.length)) { value, range, _ in
                guard let marker = value as? BookmarkMarker else { return }
                for index in range.location..<NSMaxRange(range) { bookmarks.append((index, marker.bookmark)) }
            }
            if !bookmarks.isEmpty {
                return BookmarkedParagraphFragment(textElement: textElement, range: textElement.elementRange, bookmarks: bookmarks)
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func preferencesChanged() {
        let spellCheck = UserDefaults.standard.bool(forKey: PreferenceKey.spellCheck)
        if textView.isContinuousSpellCheckingEnabled != spellCheck { textView.isContinuousSpellCheckingEnabled = spellCheck }
        let latest = EditorStyle.current()
        guard latest != style else { return }
        style = latest
        fontCache = [:]
        textView.maxTextWidth = CGFloat(style.width)
        if let length = textView.textStorage?.length, length > 0 {
            refreshDisplay(in: NSRange(location: 0, length: length))
        }
        resetTypingAttributes()
    }

    // MARK: Saving

    private func markDirty(_ id: FileID) {
        dirty.insert(id)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    /// Saves any unsaved edits and remembers where the cursor is.
    func commit(recordingPosition: Bool = true) {
        saveTimer?.invalidate()
        saveTimer = nil
        if recordingPosition { recordPosition() }
        guard let model, !dirty.isEmpty, let storage = textView.textStorage else { return }
        for id in dirty {
            let body = segments.first { $0.fileID == id && $0.role == .body }
                .map { TextBridge.blocks(from: storage.attributedSubstring(from: $0.range)) }
            let outline = segments.first { $0.fileID == id && $0.role == .outline }
                .map { TextBridge.blocks(from: storage.attributedSubstring(from: $0.range), emptyMeansNone: true) }
            model.updateContent(id, body: body, outline: outline)
        }
        dirty = []
    }

    // MARK: Remembering your place

    /// The cursor's rectangle in text view coordinates, laying out text up to it if needed.
    /// Measured from the paragraph's own line layout, the same way the margin bookmark icons are placed.
    private func caretRect(at location: Int) -> CGRect? {
        guard let layout = textView.textLayoutManager, let content = textView.textContentStorage,
              let target = content.location(content.documentRange.location, offsetBy: location),
              let upToTarget = NSTextRange(location: content.documentRange.location, end: target) else { return nil }
        layout.ensureLayout(for: upToTarget)
        guard let fragment = layout.textLayoutFragment(for: target) else { return nil }
        let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let index = location - paragraphStart
        let lines = fragment.textLineFragments
        guard let line = lines.first(where: {
            NSLocationInRange(index, $0.characterRange) || index == NSMaxRange($0.characterRange)
        }) ?? lines.last else { return nil }
        let bounds = line.typographicBounds
        let frame = fragment.layoutFragmentFrame
        let origin = textView.textContainerOrigin
        return CGRect(
            x: origin.x + frame.minX + bounds.minX + line.locationForCharacter(at: index).x,
            y: origin.y + frame.minY + bounds.minY,
            width: 1,
            height: max(bounds.height, 1)
        )
    }

    private func recordPosition() {
        guard remembersPosition, let model, !shown.isEmpty else { return }
        let cursor = textView.selectedRange().location
        guard let segment = segments.first(where: { $0.contains(NSRange(location: cursor, length: 0)) }) else { return }
        let offset = caretRect(at: cursor).map { $0.minY - textView.visibleRect.minY } ?? 0
        model.positions[segment.fileID] = FilePosition(
            inOutline: segment.role == .outline,
            cursor: cursor - segment.range.location,
            viewportOffset: Double(offset),
            lastActive: .now
        )
    }

    /// Puts the cursor back where it was in the most recently used of the shown files.
    private func restorePosition() {
        guard remembersPosition, let model else { return }
        let candidates = shown.compactMap { file in model.positions[file.id].map { (file.id, $0) } }
        guard let (id, position) = candidates.max(by: { $0.1.lastActive < $1.1.lastActive }),
              let segment = segments.first(where: { $0.fileID == id && ($0.role == .outline) == position.inOutline })
        else {
            textView.scroll(.zero)
            return
        }
        let location = segment.range.location + min(max(position.cursor, 0), segment.range.length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        if let rect = caretRect(at: location) {
            textView.scroll(NSPoint(x: 0, y: max(0, rect.minY - CGFloat(position.viewportOffset))))
        }
    }
}
