//
//  NotesZoomCoordinator.swift
//  Keynote Outliner
//

import AppKit
import Foundation

@MainActor
final class NotesZoomCoordinator {
    enum Direction {
        case increase
        case decrease
    }

    private struct ActiveTextAnchor {
        let textView: NSTextView
        let selectedIndex: Int
        let offsetFromViewportTop: CGFloat
    }

    private struct TopRowAnchor {
        let rowID: String
        let minY: CGFloat
    }

    private struct ZoomSnapshot {
        let activeTextAnchor: ActiveTextAnchor?
        let topRowAnchor: TopRowAnchor?
    }

    private weak var outerScrollView: NSScrollView?
    private var rowMinYByID: [String: CGFloat] = [:]
    private var restoreGeneration = 0

    func register(scrollView: NSScrollView) {
        outerScrollView = scrollView
    }

    func updateRowMinY(_ values: [String: CGFloat]) {
        rowMinYByID = values
    }

    func performZoom(_ direction: Direction, viewModel: OutlinerViewModel) {
        let snapshot = captureSnapshot()

        switch direction {
        case .increase:
            viewModel.increaseNoteFontSize()
        case .decrease:
            viewModel.decreaseNoteFontSize()
        }

        restoreGeneration += 1
        let generation = restoreGeneration
        scheduleRestore(snapshot, generation: generation)
    }

    private func captureSnapshot() -> ZoomSnapshot {
        ZoomSnapshot(
            activeTextAnchor: captureActiveTextAnchor(),
            topRowAnchor: captureTopRowAnchor()
        )
    }

    private func scheduleRestore(_ snapshot: ZoomSnapshot, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.restore(snapshot, generation: generation)
            DispatchQueue.main.async { [weak self] in
                self?.restore(snapshot, generation: generation)
            }
        }
    }

    private func restore(_ snapshot: ZoomSnapshot, generation: Int) {
        guard generation == restoreGeneration else { return }

        if let activeTextAnchor = snapshot.activeTextAnchor,
           restoreActiveTextAnchor(activeTextAnchor)
        {
            return
        }

        if let topRowAnchor = snapshot.topRowAnchor {
            restoreTopRowAnchor(topRowAnchor)
        }
    }

    private func captureActiveTextAnchor() -> ActiveTextAnchor? {
        guard
            let outerScrollView,
            let documentView = outerScrollView.documentView,
            let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
            textView.isDescendant(of: documentView)
        else {
            return nil
        }

        let selectedIndex = selectedCharacterIndex(in: textView)
        guard let caretRect = caretRect(forCharacterIndex: selectedIndex, in: textView) else {
            return nil
        }

        let caretInDocument = documentView.convert(caretRect, from: textView)
        let offsetFromViewportTop = verticalDistanceFromViewportTop(
            for: caretInDocument,
            in: documentView
        )

        return ActiveTextAnchor(
            textView: textView,
            selectedIndex: selectedIndex,
            offsetFromViewportTop: offsetFromViewportTop
        )
    }

    private func restoreActiveTextAnchor(_ anchor: ActiveTextAnchor) -> Bool {
        guard
            let outerScrollView,
            let documentView = outerScrollView.documentView,
            anchor.textView.window != nil,
            anchor.textView.isDescendant(of: documentView),
            let caretRect = caretRect(forCharacterIndex: anchor.selectedIndex, in: anchor.textView)
        else {
            return false
        }

        let caretInDocument = documentView.convert(caretRect, from: anchor.textView)
        let currentOffset = verticalDistanceFromViewportTop(for: caretInDocument, in: documentView)
        let delta: CGFloat =
            documentView.isFlipped
            ? (currentOffset - anchor.offsetFromViewportTop)
            : (anchor.offsetFromViewportTop - currentOffset)

        scrollOuterView(by: delta)
        return true
    }

    private func captureTopRowAnchor() -> TopRowAnchor? {
        let candidates = rowMinYByID.filter { _, minY in
            minY.isFinite && !minY.isNaN
        }

        guard !candidates.isEmpty else { return nil }

        // Keep whichever row top is nearest to viewport top, preferring partially visible rows.
        if let partial = candidates
            .filter({ $0.value <= 0 })
            .max(by: { $0.value < $1.value })
        {
            return TopRowAnchor(rowID: partial.key, minY: partial.value)
        }

        if let first = candidates.min(by: { $0.value < $1.value }) {
            return TopRowAnchor(rowID: first.key, minY: first.value)
        }

        return nil
    }

    private func restoreTopRowAnchor(_ anchor: TopRowAnchor) {
        guard let currentMinY = rowMinYByID[anchor.rowID] else { return }
        let delta = currentMinY - anchor.minY
        scrollOuterView(by: delta)
    }

    private func scrollOuterView(by delta: CGFloat) {
        guard abs(delta) > 0.1 else { return }
        guard let outerScrollView, let documentView = outerScrollView.documentView else { return }

        let clipView = outerScrollView.contentView
        var origin = clipView.bounds.origin
        origin.y += delta

        let maxY = max(documentView.bounds.height - clipView.bounds.height, 0)
        origin.y = min(max(origin.y, 0), maxY)

        guard origin != clipView.bounds.origin else { return }

        clipView.setBoundsOrigin(origin)
        outerScrollView.reflectScrolledClipView(clipView)
    }

    private func selectedCharacterIndex(in textView: NSTextView) -> Int {
        if let selectionValue = textView.selectedRanges.first as? NSValue {
            return selectionValue.rangeValue.location
        }
        return textView.selectedRange().location
    }

    private func verticalDistanceFromViewportTop(for rectInDocument: NSRect, in documentView: NSView) -> CGFloat {
        let visibleRect = documentView.visibleRect
        if documentView.isFlipped {
            return rectInDocument.minY - visibleRect.minY
        }
        return visibleRect.maxY - rectInDocument.maxY
    }

    private func caretRect(forCharacterIndex index: Int, in textView: NSTextView) -> NSRect? {
        guard
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return nil
        }

        let textLength = textView.string.utf16.count

        if layoutManager.numberOfGlyphs == 0 {
            let fallbackHeight = max(textView.font?.pointSize ?? OutlinerViewModel.defaultNoteFontSize, 1)
            return NSRect(
                x: textView.textContainerOrigin.x,
                y: textView.textContainerOrigin.y,
                width: 1,
                height: fallbackHeight
            )
        }

        let clampedIndex = max(0, min(index, textLength))
        let characterIndexForGlyphLookup = min(clampedIndex, max(textLength - 1, 0))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndexForGlyphLookup)

        var lineRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineRange,
            withoutAdditionalLayout: true
        )

        let origin = textView.textContainerOrigin
        let height = max(lineRect.height, textView.font?.pointSize ?? OutlinerViewModel.defaultNoteFontSize)
        return NSRect(x: origin.x, y: origin.y + lineRect.minY, width: 1, height: height)
    }
}
