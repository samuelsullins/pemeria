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
    /// True while reloading because this editor is taking focus (see didBecomeFirstResponder).
    private var isTakingFocus = false
    /// The model's text version of each part shown, as loaded or last saved from here.
    private var loadedVersions: [TextPart: Int] = [:]
    private var handledJumpID = -1
    private var handledFocusRequest: Int?
    /// Files whose header copy icon is showing a checkmark for a moment.
    private var recentlyCopied: Set<FileID> = []
    private var dirty: Set<FileID> = []
    /// Files whose title line has been edited here and not yet saved as their name.
    private var dirtyTitles: Set<FileID> = []
    /// Each segment's comments and bookmarks, worked out from its whole text (they can span
    /// lines). Dropped whenever that segment's text changes.
    private var annotationCache: [Int: SegmentAnnotations] = [:]
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
        // Room below the last line for typewriter scrolling (EditorTextView).
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.textView.updateOverscroll() }
        })
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
        let key = files.map { ShownFile(id: $0.id, kind: $0.kind, indents: $0.indents) }
        // Text another editor has saved since this one loaded it (the other pane of a split
        // showing the same file). Reloaded unless there's typing here not yet saved, which can't
        // really happen: focusing an editor first saves the others (didBecomeFirstResponder).
        let changedElsewhere = dirty.isEmpty && loadedVersions.contains { model.textVersion(of: $0.key) != $0.value }
        if key != shown || mode != self.mode || model.contentToken != loadedToken || changedElsewhere {
            // Same files, shown the same way or with the outline pinned/unpinned: hold your place
            // in the text rather than jumping back to the last saved cursor.
            let showsDraftText: Set<EditorMode> = [.full, .bodies]
            let keepsPlace = key.map(\.id) == shown.map(\.id) && !shown.isEmpty
                && (mode == self.mode || (showsDraftText.contains(mode) && showsDraftText.contains(self.mode)))
            let place = keepsPlace ? currentPlace() : nil
            self.mode = mode
            loadedToken = model.contentToken
            show(files, keeping: place)
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
        guard let model else { return }
        // Save what the other editors are holding, and pick it up here before you type, so two
        // editors showing the same file never hold different copies of it.
        model.commitEditors()
        // A click brought focus here: the cursor goes where it lands, not back to where it was.
        isTakingFocus = true
        sync(with: model, mode: mode)
        isTakingFocus = false
        model.activate(pane: pane)
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

    private func show(_ files: [PemeriaFile], keeping place: Place? = nil) {
        // Edits are normally saved before the selection changes; this is the safety net.
        if !dirty.isEmpty || !dirtyTitles.isEmpty { commit(recordingPosition: false) }
        let content = EditorContent(files: files, mode: mode)
        isQuiet = true
        segments = content.segments
        annotationCache = [:]
        markers = content.markers
        pieces = content.pieces
        textView.textStorage?.setAttributedString(content.text)
        isQuiet = false
        shown = files.map { ShownFile(id: $0.id, kind: $0.kind, indents: $0.indents) }
        loadedVersions = [:]
        if let model {
            for segment in segments where segment.role != .title {
                let part = TextPart(fileID: segment.fileID, inOutline: segment.role == .outline)
                loadedVersions[part] = model.textVersion(of: part)
            }
        }
        textView.isEditable = mode != .reading
        textView.undoManager?.removeAllActions()
        let firstText = segments.first { $0.role != .title } ?? segments.first
        textView.setSelectedRange(NSRange(location: firstText?.range.location ?? 0, length: 0))
        resetTypingAttributes()
        let restoresCursor = !isTakingFocus
        DispatchQueue.main.async { [weak self] in
            if let place { self?.restore(place, cursor: restoresCursor) } else { self?.restorePosition() }
        }
    }

    // MARK: Holding your place across a reload

    /// Where the view is: the paragraph at the top of the window and how far down it is
    /// scrolled, plus the cursor, each relative to its file's text rather than the whole editor.
    struct Place {
        var topFile: FileID
        var topRole: EditorSegment.Role
        var topParagraph: Int
        var topOffset: CGFloat
        var cursor: (file: FileID, role: EditorSegment.Role, offset: Int, length: Int)?
    }

    private func currentPlace() -> Place? {
        guard let storage = textView.textStorage, let layout = textView.textLayoutManager,
              let content = textView.textContentStorage else { return nil }
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: max(0, visible.minY - origin.y))) else { return nil }
        let location = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        // A header or divider line belongs with the text after it.
        let segment = segments.first { NSLocationInRange(location, $0.range) || location == NSMaxRange($0.range) }
            ?? segments.first { $0.range.location >= location }
        guard let segment else { return nil }
        let string = storage.string as NSString
        let clamped = min(max(location, segment.range.location), NSMaxRange(segment.range))
        let before = NSRange(location: segment.range.location, length: clamped - segment.range.location)
        let paragraph = string.substring(with: before).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let paragraphStart = paragraphStart(paragraph, in: segment)
        let top = caretRect(at: paragraphStart)?.minY ?? visible.minY
        var place = Place(topFile: segment.fileID, topRole: segment.role, topParagraph: paragraph, topOffset: visible.minY - top)
        let selection = textView.selectedRange()
        if let cursorSegment = segments.first(where: { $0.contains(selection) }) {
            place.cursor = (cursorSegment.fileID, cursorSegment.role, selection.location - cursorSegment.range.location, selection.length)
        }
        return place
    }

    /// Where paragraph `index` of a segment starts (its last paragraph if there are fewer).
    private func paragraphStart(_ index: Int, in segment: EditorSegment) -> Int {
        guard let storage = textView.textStorage else { return segment.range.location }
        let string = storage.string as NSString
        let end = NSMaxRange(segment.range)
        var start = segment.range.location
        for _ in 0..<index {
            let next = string.range(of: "\n", options: .literal, range: NSRange(location: start, length: end - start))
            guard next.location != NSNotFound else { break }
            start = next.location + 1
        }
        return start
    }

    private func restore(_ place: Place, cursor restoresCursor: Bool = true) {
        if restoresCursor, let cursor = place.cursor,
           let segment = segments.first(where: { $0.fileID == cursor.file && $0.role == cursor.role }) {
            let location = segment.range.location + min(cursor.offset, segment.range.length)
            textView.setSelectedRange(NSRange(location: location, length: min(cursor.length, NSMaxRange(segment.range) - location)))
        }
        // If the top paragraph's part has gone (an outline, now pinned), hold on to the end of the
        // file's text just above it instead.
        let target: Int
        let offset: CGFloat
        if let segment = segments.first(where: { $0.fileID == place.topFile && $0.role == place.topRole }) {
            target = paragraphStart(place.topParagraph, in: segment)
            offset = place.topOffset
        } else if let segment = segments.last(where: { $0.fileID == place.topFile }) {
            target = paragraphStart(.max, in: segment)
            offset = 0
        } else {
            return
        }
        if let rect = caretRect(at: target) {
            textView.scroll(NSPoint(x: 0, y: max(0, rect.minY + offset)))
        }
    }

    private func refreshHeaderTitles(_ files: [PemeriaFile]) {
        let titles = Dictionary(files.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for marker in markers where marker.kind == .fileHeader {
            guard let title = titles[marker.fileID], title != marker.title else { continue }
            marker.title = title
            if let range = range(of: marker) { refreshDisplay(in: range) }
        }
        // A file renamed elsewhere (the sidebar, the header, the other pane): its title line
        // follows, unless it's being edited here.
        guard let storage = textView.textStorage else { return }
        for index in segments.indices where segments[index].role == .title {
            let segment = segments[index]
            guard !dirtyTitles.contains(segment.fileID), let title = titles[segment.fileID],
                  NSMaxRange(segment.range) <= storage.length,
                  (storage.string as NSString).substring(with: segment.range) != title else { continue }
            let selection = textView.selectedRange()
            let delta = (title as NSString).length - segment.range.length
            isQuiet = true
            storage.replaceCharacters(in: segment.range, with: NSAttributedString(string: title))
            isQuiet = false
            segments[index].range.length += delta
            for later in segments.indices where later > index {
                segments[later].range.location += delta
            }
            annotationCache = [:]
            refreshTitleLine(of: segment.fileID)
            // The text moved under any undo steps recorded before it.
            textView.undoManager?.removeAllActions()
            if selection.location > NSMaxRange(segment.range) {
                textView.setSelectedRange(NSRange(location: selection.location + delta, length: selection.length))
            } else if selection.location >= segment.range.location {
                textView.setSelectedRange(NSRange(location: min(selection.location, NSMaxRange(segments[index].range)), length: 0))
            }
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

    /// ⌘A: the part of a file the cursor is in. In a title, just the title; anywhere in a file's
    /// text (or its outline), all of that text, without the title above it.
    var selectAllRange: NSRange? {
        let selection = textView.selectedRange()
        if let index = segmentIndex(containing: NSRange(location: selection.location, length: 0)) {
            return segments[index].range
        }
        // On a divider or header line: the text that follows it.
        return segments.first { $0.range.location >= selection.location && $0.role != .title }?.range
    }

    /// The font the cursor's line is shown in: the title's, or the text's. Read from the
    /// segments rather than the typing attributes, which can briefly hold a marker's.
    func displayFont(at location: Int) -> NSFont {
        let segment = segments.first { $0.contains(NSRange(location: location, length: 0)) }
        return segment?.role == .title ? titleFont() : font(for: 0)
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
        // A title is one line.
        if let strings = replacementStrings, strings.contains(where: { $0.contains("\n") }),
           affectedRanges.contains(where: { segmentIndex(containing: $0.rangeValue).map { segments[$0].role == .title } ?? false }) {
            NSSound.beep()
            return false
        }
        return true
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
        if segments[index].role == .title {
            // Saved as the file's name; it has no comments or indents to keep up to date.
            if editedMask.contains(.editedCharacters) {
                dirtyTitles.insert(segments[index].fileID)
                scheduleSave()
                let fileID = segments[index].fileID
                DispatchQueue.main.async { [weak self] in self?.refreshTitleLine(of: fileID) }
            }
            return
        }
        markDirty(segments[index].fileID)

        // A comment spanning lines colours lines other than the edited one, so when what spans
        // what changes (typing a closing \, say), redraw the whole file's text.
        if editedMask.contains(.editedCharacters) {
            let previous = annotationCache.removeValue(forKey: index)
            DispatchQueue.main.async { [weak self] in
                guard let self, index < self.segments.count, let current = self.annotations(forSegment: index) else { return }
                if previous?.spans ?? [] != current.spans { self.refreshDisplay(in: self.segments[index].range) }
            }
        }

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

    /// Redraws a file's title line and the line after it. The text system restyles the edited
    /// lines before the segment map has caught up with the edit, so after a title gets shorter
    /// the first line of the file's text was styled as if it were still part of the title.
    private func refreshTitleLine(of fileID: FileID) {
        guard let storage = textView.textStorage,
              let title = segments.first(where: { $0.fileID == fileID && $0.role == .title })?.range,
              NSMaxRange(title) <= storage.length else { return }
        let string = storage.string as NSString
        var stop = min(NSMaxRange(title) + 1, string.length)
        if stop < string.length {
            let lineEnd = string.range(of: "\n", options: .literal, range: NSRange(location: stop, length: string.length - stop)).location
            stop = lineEnd == NSNotFound ? string.length : lineEnd + 1
        }
        refreshDisplay(in: NSRange(location: title.location, length: stop - title.location))
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
        let string = storage.string as NSString
        for piece in pieces {
            switch piece {
            case .marker:
                start = markerLocations[markerIndex] + 2
                markerIndex += 1
            case .segment(let index):
                start = min(start, storage.length)
                let end: Int
                if rebuilt[index].role == .title {
                    // A title is one line, and its file's text follows on the next.
                    let lineEnd = string.range(of: "\n", options: .literal, range: NSRange(location: start, length: storage.length - start)).location
                    end = lineEnd == NSNotFound ? storage.length : lineEnd
                } else {
                    end = markerIndex < markerLocations.count ? markerLocations[markerIndex] - 1 : storage.length
                }
                rebuilt[index].range = NSRange(location: start, length: max(0, end - start))
                start = end + 1
            }
        }
        segments = rebuilt
        annotationCache = [:]
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
                                             ofLine: string.substring(with: line),
                                             excluding: annotations(ofLineAt: lineStart)?.annotations.map(\.range))
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
        let raw = (attributes[.pemeriaStyle] as? NSNumber)?.uint8Value ?? 0
        let location = textView.selectedRange().location
        let segment = segments.first { $0.contains(NSRange(location: location, length: 0)) }
        if segment?.role == .title {
            attributes[.pemeriaStyle] = nil
            attributes[.font] = titleFont()
            attributes[.foregroundColor] = NSColor.textColor
            attributes[.paragraphStyle] = titleParagraphStyle()
            textView.typingAttributes = attributes
            return
        }
        attributes[.font] = font(for: raw)
        attributes[.foregroundColor] = segment?.role == .outline && dimsOutlines ? NSColor.secondaryLabelColor : NSColor.textColor
        attributes[.paragraphStyle] = paragraphStyle(indented: segment?.isIndented ?? false)
        textView.typingAttributes = attributes
    }

    /// Return on a title line goes down to the start of the file's text instead of breaking
    /// the line.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
               #selector(NSResponder.insertParagraphSeparator(_:))].contains(commandSelector),
              isInTitle else { return false }
        let selection = textView.selectedRange()
        if let index = segmentIndex(containing: selection), index + 1 < segments.count {
            textView.setSelectedRange(NSRange(location: segments[index + 1].range.location, length: 0))
        }
        return true
    }

    /// Whether the cursor or selection is on a title line.
    private var isInTitle: Bool {
        segmentIndex(containing: textView.selectedRange()).map { segments[$0].role == .title } ?? false
    }

    // MARK: Clicks on margin and marker icons

    /// Handles a click on a divider's pin or a file header's copy icon.
    /// Returns false for any other click.
    func handleClick(at point: NSPoint) -> Bool {
        guard let layout = textView.textLayoutManager else { return false }
        let origin = textView.textContainerOrigin
        let containerPoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: containerPoint) as? MarkerFragment,
              let target = fragment.buttonRect?.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY),
              target.insetBy(dx: -6, dy: -6).contains(containerPoint) else { return false }
        switch fragment.kind {
        case .outlineDivider:
            model?.setOutlinePinned(true, pane: pane)
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

    /// ⌘D: starts a `#` bookmark at the cursor (SPEC.md §7).
    func insertBookmark() {
        insertOpener("#")
    }

    /// ⌘/: starts a `//` comment at the cursor.
    func insertComment() {
        insertOpener("//")
    }

    /// Types `opener` and a space at the start of the selection, with a space before it if the
    /// character before isn't one already (a comment or bookmark only starts after whitespace).
    private func insertOpener(_ opener: String) {
        guard textView.isEditable, !isInTitle, let storage = textView.textStorage else { NSSound.beep(); return }
        let location = textView.selectedRange().location
        let string = storage.string as NSString
        let needsSpace = location > 0 && !(Character(UnicodeScalar(string.character(at: location - 1)) ?? " ").isWhitespace)
        textView.insertText(needsSpace ? " \(opener) " : "\(opener) ", replacementRange: NSRange(location: location, length: 0))
    }

    /// ⇧⌘D: marks the comment at the cursor Done (`//x`), or not done again.
    func toggleCommentDone() {
        guard textView.isEditable, let storage = textView.textStorage else { NSSound.beep(); return }
        let cursor = textView.selectedRange().location
        guard let index = segments.firstIndex(where: { $0.contains(NSRange(location: cursor, length: 0)) }),
              segments[index].role != .title,
              let map = annotations(forSegment: index) else { NSSound.beep(); return }
        let segmentStart = segments[index].range.location
        var line = map.line(containing: cursor - segmentStart)
        // The comment the cursor is in or just after; failing that, the line's first comment.
        let inLine = cursor - segmentStart - map.lineStarts[line]
        let comments = map.lines[line].filter { $0.kind == .comment }
        guard var comment = comments.first(where: { $0.range.location <= inLine && inLine <= NSMaxRange($0.range) }) ?? comments.first
        else { NSSound.beep(); return }
        // On a later line of one spanning lines: its x goes after the // on the line it opens on.
        while !comment.opensHere, line > 0, let previous = map.lines[line - 1].last {
            line -= 1
            comment = previous
        }
        let string = storage.string as NSString
        let mark = segmentStart + map.lineStarts[line] + comment.range.location + 2
        let after = mark < string.length ? string.character(at: mark) : 0x0A
        let needsSpace = !comment.isDone && after != 0x0A && after != Comments.closer
            && !(Character(UnicodeScalar(after) ?? " ").isWhitespace)
        let range = comment.isDone ? NSRange(location: mark, length: 1) : NSRange(location: mark, length: 0)
        let replacement = comment.isDone ? "" : (needsSpace ? "x " : "x")
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        let selection = textView.selectedRange()
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        // Keep the cursor on the same character.
        let delta = (replacement as NSString).length - range.length
        if selection.location >= mark { textView.setSelectedRange(NSRange(location: max(mark, selection.location + delta), length: 0)) }
    }

    // MARK: Comments spanning lines

    /// One segment's comments and bookmarks, line by line.
    struct SegmentAnnotations {
        /// Where each line starts, from the start of the segment.
        var lineStarts: [Int]
        var lines: [[Comments.Annotation]]
        var length: Int

        /// The lines each comment or bookmark spanning lines covers, with what it is: when this
        /// changes, lines other than the edited one need redrawing.
        var spans: [[Int]] {
            var spans: [[Int]] = []
            var start: Int?
            for (index, line) in lines.enumerated() {
                for part in line {
                    if part.opensHere, part.continues { start = index }
                    // The last line of one spanning lines: it didn't open here and stops here.
                    if !part.opensHere, !part.continues {
                        spans.append([start ?? 0, index, part.kind == .comment ? 0 : 1, part.isDone ? 1 : 0])
                        start = nil
                    }
                }
            }
            return spans
        }

        /// The line holding `offset` (from the start of the segment).
        func line(containing offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return low
        }
    }

    private func annotations(forSegment index: Int) -> SegmentAnnotations? {
        guard let storage = textView.textStorage, segments.indices.contains(index),
              NSMaxRange(segments[index].range) <= storage.length else { return nil }
        let range = segments[index].range
        if let cached = annotationCache[index], cached.length == range.length { return cached }
        let lines = (storage.string as NSString).substring(with: range).components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        let result = SegmentAnnotations(lineStarts: starts, lines: Comments.annotations(inLines: lines), length: range.length)
        annotationCache[index] = result
        return result
    }

    /// The comments and bookmarks on the line starting at `location`, read with the lines
    /// around it; nil outside the files' text (header and divider lines).
    private func annotations(ofLineAt location: Int) -> (lineStart: Int, annotations: [Comments.Annotation])? {
        guard let index = segments.firstIndex(where: { $0.contains(NSRange(location: location, length: 0)) }),
              let map = annotations(forSegment: index) else { return nil }
        let line = map.line(containing: location - segments[index].range.location)
        return (segments[index].range.location + map.lineStarts[line], map.lines[line])
    }

    /// Moves to a comment or bookmark chosen in the right panel, if it's in this editor.
    private func handlePendingJump() {
        guard let model, let request = model.jumpRequest, request.id != handledJumpID, isInActivePane else { return }
        let role: EditorSegment.Role = request.location.inOutline ? .outline : .body
        guard mode != .reading, segments.contains(where: { $0.fileID == request.location.fileID && $0.role == role }) else { return }
        handledJumpID = request.id
        // After any pending reload/position restore.
        DispatchQueue.main.async { [weak self] in
            self?.jump(to: request.location)
            if model.jumpRequest?.id == request.id { model.jumpRequest = nil }
        }
    }

    private func jump(to location: TextLocation) {
        let role: EditorSegment.Role = location.inOutline ? .outline : .body
        guard let storage = textView.textStorage,
              let segment = segments.first(where: { $0.fileID == location.fileID && $0.role == role }) else { return }
        let string = storage.string as NSString
        let end = NSMaxRange(segment.range)
        var lineStart = segment.range.location
        for _ in 0..<location.paragraph {
            let next = string.range(of: "\n", options: .literal, range: NSRange(location: lineStart, length: end - lineStart))
            guard next.location != NSNotFound else { break }
            lineStart = next.location + 1
        }
        let lineEnd = string.range(of: "\n", options: .literal, range: NSRange(location: lineStart, length: end - lineStart)).location
        let lineLength = (lineEnd == NSNotFound ? end : lineEnd) - lineStart
        let start = lineStart + min(location.range.location, lineLength)
        let target = NSRange(location: start, length: min(NSMaxRange(location.range), lineLength) - (start - lineStart))
        textView.setSelectedRange(NSRange(location: target.location, length: 0))
        if let rect = caretRect(at: target.location) {
            textView.scroll(NSPoint(x: 0, y: max(0, rect.minY - textView.visibleRect.height / 3)))
        }
        if target.length > 0 { textView.showFindIndicator(for: target) }
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Italic and bold

    func toggle(_ trait: InlineStyle) {
        guard let storage = textView.textStorage else { return }
        // Titles are plain: a file's name has no italics.
        if isInTitle { NSSound.beep(); return }
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
        if isInTitle {
            // Into a title: one line, no italics.
            result.mutableString.replaceOccurrences(of: "\n", with: " ", options: .literal,
                                                    range: NSRange(location: 0, length: result.length))
            result.removeAttribute(.pemeriaStyle, range: NSRange(location: 0, length: result.length))
        }
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

        // Remove divider lines (the marker character plus its line break), last first.
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
        copy.mutableString.replaceOccurrences(of: String(TextBridge.markerCharacter), with: "", options: .literal,
                                              range: NSRange(location: 0, length: copy.length))

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

    /// A file's title line: the text's own typeface, larger and bold.
    private func titleFont() -> NSFont {
        let bold = font(for: InlineStyle.bold.rawValue)
        return NSFont(descriptor: bold.fontDescriptor, size: CGFloat(style.fontSize * 1.5)) ?? bold
    }

    private func titleParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.1
        paragraph.paragraphSpacing = CGFloat(style.fontSize * 0.9)
        paragraph.alignment = .natural
        return paragraph
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
            let height: CGFloat = switch marker.kind {
            case .fileHeader: marker.showsTitle ? 64 : 48
            case .outlineDivider: 44
            }
            display.addAttributes([
                .paragraphStyle: markerParagraphStyle(height: height),
                .foregroundColor: NSColor.clear,
                .font: font(for: 0),
            ], range: whole)
            return NSTextParagraph(attributedString: display)
        }

        let segment = segments.first { $0.contains(NSRange(location: range.location, length: 0)) }
        if segment?.role == .title {
            display.setAttributes([
                .font: titleFont(),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: titleParagraphStyle(),
            ], range: whole)
            return NSTextParagraph(attributedString: display)
        }
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
        // Comments are quiet; Done ones quieter still, and struck through. Bookmarks are in the
        // accent colour, since they're for finding your way.
        let inDimOutline = segment?.role == .outline && dimsOutlines
        for annotation in annotations(ofLineAt: range.location)?.annotations ?? Comments.annotations(in: display.string) {
            switch annotation.kind {
            case .comment where annotation.isDone:
                display.addAttributes([
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.tertiaryLabelColor,
                ], range: annotation.range)
            case .comment:
                display.addAttribute(.foregroundColor,
                                     value: inDimOutline ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                                     range: annotation.range)
            case .bookmark:
                display.addAttribute(.foregroundColor,
                                     value: Theme.accent.withAlphaComponent(inDimOutline ? 0.6 : 1),
                                     range: annotation.range)
            }
        }
        return NSTextParagraph(attributedString: display)
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let line = paragraph.attributedString
            if let marker = line.attribute(.pemeriaMarker, at: 0, effectiveRange: nil) as? EditorMarker {
                let kind: MarkerFragment.Kind = switch marker.kind {
                case .fileHeader: .fileHeader(fileID: marker.fileID, title: marker.showsTitle ? marker.title : nil,
                                              copied: recentlyCopied.contains(marker.fileID))
                case .outlineDivider: .outlineDivider
                }
                let fragment = MarkerFragment(textElement: textElement, range: textElement.elementRange, kind: kind)
                fragment.hasCopyButton = mode != .outlines && mode != .outlineView
                // Outlines on their own (pinned pane, Outline view) get names but no rule.
                fragment.hasRule = mode != .outlines && mode != .outlineView
                return fragment
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func preferencesChanged() {
        textView.updateOverscroll()
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
        scheduleSave()
    }

    /// Saves a second after typing pauses.
    private func scheduleSave() {
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
        guard let model, let storage = textView.textStorage else { return }
        // Edited title lines rename their files. One emptied out is left as it is, unsaved,
        // while you type a new name; if you leave it empty the file keeps its old name.
        for id in dirtyTitles {
            guard let segment = segments.first(where: { $0.fileID == id && $0.role == .title }),
                  NSMaxRange(segment.range) <= storage.length else { dirtyTitles.remove(id); continue }
            let title = (storage.string as NSString).substring(with: segment.range)
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            model.rename(id, to: title)
            dirtyTitles.remove(id)
        }
        guard !dirty.isEmpty else { return }
        for id in dirty {
            let body = segments.first { $0.fileID == id && $0.role == .body }
                .map { TextBridge.blocks(from: storage.attributedSubstring(from: $0.range)) }
            let outline = segments.first { $0.fileID == id && $0.role == .outline }
                .map { TextBridge.blocks(from: storage.attributedSubstring(from: $0.range), emptyMeansNone: true) }
            let saved = model.updateContent(id, body: body, outline: outline, basedOn: loadedVersions)
            loadedVersions.merge(saved) { _, new in new }
        }
        dirty = []
    }

    // MARK: Remembering your place

    /// The cursor's rectangle in text view coordinates, laying out text up to it if needed.
    /// Measured from the paragraph's own line layout.
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
        guard let segment = segments.first(where: { $0.contains(NSRange(location: cursor, length: 0)) }),
              segment.role != .title else { return }
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
              let segment = segments.first(where: { $0.fileID == id && $0.role == (position.inOutline ? .outline : .body) })
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
