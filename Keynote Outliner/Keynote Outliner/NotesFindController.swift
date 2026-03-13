//
//  NotesFindController.swift
//  Keynote Outliner
//

import AppKit
import Foundation

struct SearchableRowSnapshot: Equatable, Sendable {
    var rowID: SlideRowModel.ID
    var text: String
    var isEditable: Bool
}

struct RowSearchSegment: Equatable, Sendable {
    var rowID: SlideRowModel.ID
    var text: String
    var isEditable: Bool
    var globalRange: NSRange
}

struct PendingRevealRequest: Equatable, Sendable {
    var rowID: SlideRowModel.ID
    var globalRange: NSRange
    var localRange: NSRange
    var activateEditor: Bool
}

@MainActor
final class NotesFindController: NSObject, NSTextFinderClient {
    private struct WeakTextView {
        weak var textView: GrowingNoteTextView?
    }

    private struct ResolvedSearchRange: Equatable {
        var rowID: SlideRowModel.ID
        var globalRange: NSRange
        var localRange: NSRange
        var isEditable: Bool
    }

    private let textFinder = NSTextFinder()

    private var rowTextViews: [SlideRowModel.ID: WeakTextView] = [:]
    private var onApplyEditedText: @MainActor (String, SlideRowModel.ID) -> Void = { _, _ in }
    private var onStatusMessage: @MainActor (String) -> Void = { _ in }
    private var onBeep: @MainActor () -> Void = { NSSound.beep() }
    private var onDebugStateChange: @MainActor (SlideRowModel.ID?, NSRange?, SlideRowModel.ID?) -> Void = { _, _, _ in }
    private var scrollToRow: @MainActor (SlideRowModel.ID) -> Void = { _ in }
    private var suppressSelectionSync = false
    private var currentAction: NSTextFinder.Action?

    private(set) var searchableRows: [SearchableRowSnapshot] = []
    private(set) var searchSegments: [RowSearchSegment] = []
    private(set) var pendingRevealRequest: PendingRevealRequest?

    private var selectedRangesStorage: [NSValue] = [NSValue(range: NSRange(location: 0, length: 0))]

    var canFind: Bool {
        !searchableRows.isEmpty
    }

    override init() {
        super.init()
        textFinder.client = self
        textFinder.isIncrementalSearchingEnabled = true
        textFinder.incrementalSearchingShouldDimContentView = false
    }

    func configure(
        applyEditedText: @escaping @MainActor (String, SlideRowModel.ID) -> Void,
        setStatusMessage: @escaping @MainActor (String) -> Void,
        beep: (@MainActor () -> Void)? = nil,
        updateDebugState: (@MainActor (SlideRowModel.ID?, NSRange?, SlideRowModel.ID?) -> Void)? = nil
    ) {
        onApplyEditedText = applyEditedText
        onStatusMessage = setStatusMessage
        if let beep {
            onBeep = beep
        }
        if let updateDebugState {
            onDebugStateChange = updateDebugState
        }
        publishDebugState()
    }

    func registerFindBarContainer(_ scrollView: NSScrollView) {
        guard textFinder.findBarContainer !== scrollView else { return }
        textFinder.findBarContainer = scrollView
    }

    func setScrollToRow(_ action: @escaping @MainActor (SlideRowModel.ID) -> Void) {
        scrollToRow = action
    }

    func updateSearchableRows(_ snapshots: [SearchableRowSnapshot]) {
        guard searchableRows != snapshots else {
            pruneRegisteredTextViews(allowedRowIDs: Set(snapshots.map(\.rowID)))
            fulfillPendingRevealIfPossible()
            return
        }

        textFinder.noteClientStringWillChange()
        searchableRows = snapshots
        rebuildSegments()
        pruneRegisteredTextViews(allowedRowIDs: Set(snapshots.map(\.rowID)))
        normalizeSelection()
        fulfillPendingRevealIfPossible()
    }

    func noteClientStringWillChange() {
        textFinder.noteClientStringWillChange()
    }

    func registerTextView(_ textView: GrowingNoteTextView, rowID: SlideRowModel.ID) {
        textView.searchRowID = rowID
        textView.notesFindController = self
        rowTextViews[rowID] = WeakTextView(textView: textView)
        fulfillPendingRevealIfPossible(for: rowID)
    }

    func unregisterTextView(_ textView: GrowingNoteTextView, rowID: SlideRowModel.ID) {
        guard rowTextViews[rowID]?.textView === textView else { return }
        rowTextViews.removeValue(forKey: rowID)
    }

    func handleVisibleTextChange(
        rowID: SlideRowModel.ID,
        text: String,
        selectedRange: NSRange
    ) {
        guard let rowIndex = searchableRows.firstIndex(where: { $0.rowID == rowID }) else { return }

        if searchableRows[rowIndex].text != text {
            textFinder.noteClientStringWillChange()
            searchableRows[rowIndex].text = text
            rebuildSegments()
        }

        syncSelection(rowID: rowID, localRange: selectedRange)
    }

    func handleSelectionChange(
        rowID: SlideRowModel.ID,
        localRange: NSRange
    ) {
        guard !suppressSelectionSync else { return }
        syncSelection(rowID: rowID, localRange: localRange)
    }

    func handleTextViewBecameFirstResponder(_ textView: GrowingNoteTextView) {
        guard let rowID = textView.searchRowID else { return }
        syncSelection(rowID: rowID, localRange: textView.selectedRange())
    }

    func performAction(_ action: NSTextFinder.Action) {
        currentAction = action
        textFinder.performAction(action)
        currentAction = nil
    }

    func performAction(for sender: Any?) -> Bool {
        guard let action = Self.textFinderAction(from: sender) else { return false }
        performAction(action)
        return true
    }

    func validateAction(_ action: NSTextFinder.Action) -> Bool {
        textFinder.validateAction(action)
    }

    func validateAction(for item: NSValidatedUserInterfaceItem) -> Bool? {
        guard let action = Self.textFinderAction(from: item) else { return nil }
        return validateAction(action)
    }

    func globalRange(forRowID rowID: SlideRowModel.ID, localRange: NSRange) -> NSRange? {
        guard let segment = searchSegments.first(where: { $0.rowID == rowID }) else { return nil }

        let clampedLocation = min(max(localRange.location, 0), segment.globalRange.length)
        let maxLength = max(segment.globalRange.length - clampedLocation, 0)
        let clampedLength = min(max(localRange.length, 0), maxLength)
        return NSRange(
            location: segment.globalRange.location + clampedLocation,
            length: clampedLength
        )
    }

    func resolvedRange(for globalRange: NSRange) -> (rowID: SlideRowModel.ID, localRange: NSRange, isEditable: Bool)? {
        guard let resolved = resolve(globalRange: globalRange) else { return nil }
        return (resolved.rowID, resolved.localRange, resolved.isEditable)
    }

    var string: String {
        searchableRows.map(\.text).joined()
    }

    var firstSelectedRange: NSRange {
        selectedRangesStorage.first?.rangeValue ?? NSRange(location: 0, length: 0)
    }

    var selectedRanges: [NSValue] {
        get { selectedRangesStorage }
        set { setSelectedRangesFromFinder(newValue) }
    }

    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { searchableRows.contains(where: \.isEditable) }

    func string(
        at characterIndex: Int,
        effectiveRange outRange: NSRangePointer,
        endsWithSearchBoundary outFlag: UnsafeMutablePointer<ObjCBool>
    ) -> String {
        let segment = segmentForStringLookup(at: characterIndex)
            ?? RowSearchSegment(
                rowID: "",
                text: "",
                isEditable: false,
                globalRange: NSRange(location: 0, length: 0)
            )

        outRange.pointee = segment.globalRange
        outFlag.pointee = true
        return segment.text
    }

    func stringLength() -> Int {
        searchSegments.last.map { NSMaxRange($0.globalRange) } ?? 0
    }

    func scrollRangeToVisible(_ range: NSRange) {
        reveal(globalRange: range, activateEditor: false)
    }

    func shouldReplaceCharacters(
        inRanges ranges: [NSValue],
        with strings: [String]
    ) -> Bool {
        let shouldReplace = ranges.allSatisfy { rangeValue in
            guard let resolved = resolve(globalRange: rangeValue.rangeValue) else { return false }
            return resolved.isEditable
        }

        guard !shouldReplace else { return true }

        if currentAction == .replace || currentAction == .replaceAndFind {
            onBeep()
            onStatusMessage("Can't replace text in a read-only note.")
        }
        return false
    }

    func replaceCharacters(in range: NSRange, with string: String) {
        guard let resolved = resolve(globalRange: range),
              let rowIndex = searchableRows.firstIndex(where: { $0.rowID == resolved.rowID })
        else {
            return
        }

        let replacementLength = (string as NSString).length
        let currentText = searchableRows[rowIndex].text as NSString
        let updatedText = currentText.replacingCharacters(in: resolved.localRange, with: string)
        let updatedSelection = NSRange(
            location: resolved.localRange.location,
            length: replacementLength
        )

        textFinder.noteClientStringWillChange()
        searchableRows[rowIndex].text = updatedText
        rebuildSegments()
        onApplyEditedText(updatedText, resolved.rowID)

        if let updatedGlobalRange = globalRange(forRowID: resolved.rowID, localRange: updatedSelection) {
            selectedRangesStorage = [NSValue(range: updatedGlobalRange)]
            pendingRevealRequest = PendingRevealRequest(
                rowID: resolved.rowID,
                globalRange: updatedGlobalRange,
                localRange: updatedSelection,
                activateEditor: true
            )
            fulfillPendingRevealIfPossible(for: resolved.rowID)
        }
    }

    func didReplaceCharacters() {
        textFinder.findIndicatorNeedsUpdate = true
    }

    func contentView(
        at index: Int,
        effectiveCharacterRange outRange: NSRangePointer
    ) -> NSView {
        let segment = segmentForStringLookup(at: index)
            ?? searchSegments.last
            ?? RowSearchSegment(
                rowID: "",
                text: "",
                isEditable: false,
                globalRange: NSRange(location: 0, length: 0)
            )

        outRange.pointee = segment.globalRange
        if let textView = registeredTextView(for: segment.rowID) {
            return textView
        }

        if let scrollView = textFinder.findBarContainer as? NSScrollView {
            return scrollView.documentView ?? scrollView.contentView
        }

        return NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let resolved = resolve(globalRange: range) else { return nil }
        guard let textView = registeredTextView(for: resolved.rowID) else {
            reveal(globalRange: range, activateEditor: false)
            return nil
        }
        return textView.selectionRects(for: resolved.localRange)
    }

    var visibleCharacterRanges: [NSValue] {
        searchSegments.compactMap { segment in
            registeredTextView(for: segment.rowID).map { _ in
                NSValue(range: segment.globalRange)
            }
        }
    }

    private func rebuildSegments() {
        var cursor = 0
        searchSegments = searchableRows.map { row in
            let length = (row.text as NSString).length
            defer { cursor += length }
            return RowSearchSegment(
                rowID: row.rowID,
                text: row.text,
                isEditable: row.isEditable,
                globalRange: NSRange(location: cursor, length: length)
            )
        }
    }

    private func pruneRegisteredTextViews(allowedRowIDs: Set<SlideRowModel.ID>) {
        rowTextViews = rowTextViews.reduce(into: [:]) { result, element in
            guard allowedRowIDs.contains(element.key),
                  let textView = element.value.textView
            else {
                return
            }
            result[element.key] = WeakTextView(textView: textView)
        }
    }

    private func registeredTextView(for rowID: SlideRowModel.ID) -> GrowingNoteTextView? {
        guard let textView = rowTextViews[rowID]?.textView else {
            rowTextViews.removeValue(forKey: rowID)
            return nil
        }
        return textView
    }

    private func setSelectedRangesFromFinder(_ ranges: [NSValue]) {
        let normalizedRanges = normalize(ranges)
        selectedRangesStorage = normalizedRanges
        publishDebugState()

        guard let range = normalizedRanges.first?.rangeValue else { return }
        reveal(globalRange: range, activateEditor: false)
    }

    private func normalize(_ ranges: [NSValue]) -> [NSValue] {
        guard !ranges.isEmpty else {
            return [NSValue(range: NSRange(location: 0, length: 0))]
        }

        let totalLength = stringLength()
        return ranges.compactMap { value in
            let range = value.rangeValue
            let clampedLocation = min(max(range.location, 0), totalLength)
            let maxLength = max(totalLength - clampedLocation, 0)
            let clampedLength = min(max(range.length, 0), maxLength)
            return NSValue(range: NSRange(location: clampedLocation, length: clampedLength))
        }
    }

    private func normalizeSelection() {
        selectedRangesStorage = normalize(selectedRangesStorage)
        publishDebugState()

        guard let pending = pendingRevealRequest else { return }
        guard resolve(globalRange: pending.globalRange) != nil else {
            pendingRevealRequest = nil
            return
        }
    }

    private func syncSelection(rowID: SlideRowModel.ID, localRange: NSRange) {
        guard let globalRange = globalRange(forRowID: rowID, localRange: localRange) else { return }
        selectedRangesStorage = [NSValue(range: globalRange)]
        publishDebugState()
    }

    private func reveal(globalRange: NSRange, activateEditor: Bool) {
        guard let resolved = resolve(globalRange: globalRange) else { return }

        selectedRangesStorage = [NSValue(range: resolved.globalRange)]

        if let textView = registeredTextView(for: resolved.rowID) {
            applySelection(
                resolved.localRange,
                globalRange: resolved.globalRange,
                to: textView,
                activateEditor: activateEditor
            )
            return
        }

        pendingRevealRequest = PendingRevealRequest(
            rowID: resolved.rowID,
            globalRange: resolved.globalRange,
            localRange: resolved.localRange,
            activateEditor: activateEditor
        )
        publishDebugState()
        scrollToRow(resolved.rowID)
    }

    private func fulfillPendingRevealIfPossible(for rowID: SlideRowModel.ID? = nil) {
        guard let pending = pendingRevealRequest else { return }
        guard rowID == nil || rowID == pending.rowID else { return }
        guard let textView = registeredTextView(for: pending.rowID) else { return }

        applySelection(
            pending.localRange,
            globalRange: pending.globalRange,
            to: textView,
            activateEditor: pending.activateEditor
        )
    }

    private func applySelection(
        _ localRange: NSRange,
        globalRange: NSRange,
        to textView: GrowingNoteTextView,
        activateEditor: Bool
    ) {
        pendingRevealRequest = nil

        suppressSelectionSync = true
        if activateEditor, let window = textView.window {
            window.makeFirstResponder(textView)
        }
        textView.setSelectedRange(localRange)
        textView.scrollRangeToVisible(localRange)
        suppressSelectionSync = false

        selectedRangesStorage = [NSValue(range: globalRange)]
        textFinder.findIndicatorNeedsUpdate = true
        publishDebugState()
    }

    private func resolve(globalRange: NSRange) -> ResolvedSearchRange? {
        guard let segment = segmentContaining(globalRange: globalRange) else { return nil }
        return ResolvedSearchRange(
            rowID: segment.rowID,
            globalRange: globalRange,
            localRange: NSRange(
                location: globalRange.location - segment.globalRange.location,
                length: globalRange.length
            ),
            isEditable: segment.isEditable
        )
    }

    private func segmentContaining(globalRange: NSRange) -> RowSearchSegment? {
        if globalRange.length == 0 {
            return segmentForInsertionPoint(globalRange.location)
        }

        return searchSegments.first { segment in
            NSLocationInRange(globalRange.location, segment.globalRange)
                && NSMaxRange(globalRange) <= NSMaxRange(segment.globalRange)
        }
    }

    private func segmentForInsertionPoint(_ location: Int) -> RowSearchSegment? {
        guard !searchSegments.isEmpty else { return nil }

        if location >= stringLength() {
            return searchSegments.last
        }

        if let exactMatch = searchSegments.first(where: { segment in
            NSLocationInRange(location, segment.globalRange)
        }) {
            return exactMatch
        }

        if let zeroLengthMatch = searchSegments.first(where: { segment in
            segment.globalRange.length == 0 && segment.globalRange.location == location
        }) {
            return zeroLengthMatch
        }

        return searchSegments.first(where: { segment in
            segment.globalRange.location >= location
        }) ?? searchSegments.last
    }

    private func segmentForStringLookup(at index: Int) -> RowSearchSegment? {
        guard !searchSegments.isEmpty else { return nil }

        let clampedIndex = min(max(index, 0), stringLength())
        return segmentForInsertionPoint(clampedIndex)
    }

    private func publishDebugState() {
        onDebugStateChange(
            resolve(globalRange: firstSelectedRange)?.rowID,
            selectedRangesStorage.first?.rangeValue,
            pendingRevealRequest?.rowID
        )
    }

    static func textFinderAction(from sender: Any?) -> NSTextFinder.Action? {
        guard let tag = tag(from: sender) else { return nil }
        return NSTextFinder.Action(rawValue: tag)
    }

    private static func tag(from sender: Any?) -> Int? {
        if let menuItem = sender as? NSMenuItem {
            return menuItem.tag
        }

        if let control = sender as? NSControl {
            return control.tag
        }

        guard let object = sender as AnyObject? else { return nil }
        guard object.responds(to: Selector(("tag"))) else { return nil }
        return object.value(forKey: "tag") as? Int
    }
}

extension NSTextView {
    fileprivate func selectionRects(for range: NSRange) -> [NSValue] {
        guard let layoutManager, let textContainer else { return [] }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSValue] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(
                NSValue(
                    rect: rect.offsetBy(
                        dx: self.textContainerOrigin.x,
                        dy: self.textContainerOrigin.y
                    )
                )
            )
        }
        return rects
    }
}
