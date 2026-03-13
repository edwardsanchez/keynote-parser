//
//  NotesFindControllerTests.swift
//  Keynote OutlinerTests
//

import AppKit
import XCTest
@testable import Keynote_Outliner

@MainActor
final class NotesFindControllerTests: XCTestCase {
    func testGlobalRangesAreSegmentedByVisibleRowOrder() {
        let controller = makeController()

        controller.updateSearchableRows([
            SearchableRowSnapshot(rowID: "slide-1", text: "hello", isEditable: true),
            SearchableRowSnapshot(rowID: "slide-2", text: "world", isEditable: true),
        ])

        XCTAssertEqual(
            controller.searchSegments.map(\.globalRange),
            [
                NSRange(location: 0, length: 5),
                NSRange(location: 5, length: 5),
            ]
        )
        XCTAssertEqual(
            controller.globalRange(forRowID: "slide-2", localRange: NSRange(location: 1, length: 3)),
            NSRange(location: 6, length: 3)
        )
    }

    func testResolvedRangeRejectsCrossRowMatches() {
        let controller = makeController()

        controller.updateSearchableRows([
            SearchableRowSnapshot(rowID: "slide-1", text: "hello", isEditable: true),
            SearchableRowSnapshot(rowID: "slide-2", text: "world", isEditable: true),
        ])

        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        var endsWithBoundary = ObjCBool(false)
        let resolvedText = controller.string(
            at: 4,
            effectiveRange: &effectiveRange,
            endsWithSearchBoundary: &endsWithBoundary
        )

        XCTAssertEqual(resolvedText, "hello")
        XCTAssertEqual(effectiveRange, NSRange(location: 0, length: 5))
        XCTAssertTrue(endsWithBoundary.boolValue)
        XCTAssertNil(controller.resolvedRange(for: NSRange(location: 4, length: 2)))
    }

    func testReplacementOnlyMutatesEditableRows() throws {
        let controller = makeController()
        var appliedTexts: [String: String] = [:]

        controller.configure(
            applyEditedText: { text, rowID in
                appliedTexts[rowID] = text
            },
            setStatusMessage: { _ in },
            beep: {}
        )
        controller.updateSearchableRows([
            SearchableRowSnapshot(rowID: "editable", text: "hello friend", isEditable: true),
            SearchableRowSnapshot(rowID: "readonly", text: "hello friend", isEditable: false),
        ])

        let editableRange = try XCTUnwrap(
            controller.globalRange(forRowID: "editable", localRange: NSRange(location: 0, length: 5))
        )
        let readOnlyRange = try XCTUnwrap(
            controller.globalRange(forRowID: "readonly", localRange: NSRange(location: 0, length: 5))
        )

        let matches = [editableRange, readOnlyRange].sorted { $0.location > $1.location }
        for range in matches {
            guard controller.shouldReplaceCharacters(inRanges: [NSValue(range: range)], with: ["bye"]) else {
                continue
            }
            controller.replaceCharacters(in: range, with: "bye")
        }

        XCTAssertEqual(appliedTexts["editable"], "bye friend")
        XCTAssertNil(appliedTexts["readonly"])
    }

    func testScopeUpdateDropsHiddenRowsFromNavigation() {
        let controller = makeController()

        controller.updateSearchableRows([
            SearchableRowSnapshot(rowID: "slide-1", text: "alpha", isEditable: true),
            SearchableRowSnapshot(rowID: "slide-2", text: "beta", isEditable: true),
            SearchableRowSnapshot(rowID: "slide-3", text: "gamma", isEditable: true),
        ])
        XCTAssertNotNil(controller.globalRange(forRowID: "slide-2", localRange: NSRange(location: 0, length: 4)))

        controller.updateSearchableRows([
            SearchableRowSnapshot(rowID: "slide-1", text: "alpha", isEditable: true),
            SearchableRowSnapshot(rowID: "slide-3", text: "gamma", isEditable: true),
        ])

        XCTAssertEqual(controller.searchSegments.map(\.rowID), ["slide-1", "slide-3"])
        XCTAssertNil(controller.globalRange(forRowID: "slide-2", localRange: NSRange(location: 0, length: 4)))
    }

    func testPendingRevealResolvesWhenTextViewRegisters() throws {
        let controller = makeController()
        var scrolledRows: [String] = []

        controller.setScrollToRow { rowID in
            scrolledRows.append(rowID)
        }
        controller.updateSearchableRows([
            SearchableRowSnapshot(rowID: "slide-1", text: "hello world", isEditable: true),
        ])

        let globalRange = try XCTUnwrap(
            controller.globalRange(forRowID: "slide-1", localRange: NSRange(location: 6, length: 5))
        )
        controller.scrollRangeToVisible(globalRange)

        XCTAssertEqual(scrolledRows, ["slide-1"])
        XCTAssertEqual(controller.pendingRevealRequest?.rowID, "slide-1")

        let textView = makeTextView(string: "hello world")
        controller.registerTextView(textView, rowID: "slide-1")

        XCTAssertNil(controller.pendingRevealRequest)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 5))
    }

    private func makeController() -> NotesFindController {
        let controller = NotesFindController()
        controller.configure(
            applyEditedText: { _, _ in },
            setStatusMessage: { _ in },
            beep: {}
        )
        return controller
    }

    private func makeTextView(string: String) -> GrowingNoteTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        )

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let textView = GrowingNoteTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240), textContainer: textContainer)
        textView.string = string
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 6)
        return textView
    }
}
