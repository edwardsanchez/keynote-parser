//
//  ContentView.swift
//  Keynote Outliner
//

import AppKit
import SwiftUI

struct ContentView: View {
    static let editorScrollCoordinateSpace = "EditorListScrollSpace"

    @Bindable var viewModel: OutlinerViewModel
    var zoomCoordinator: NotesZoomCoordinator
    var findController: NotesFindController

    var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                emptyState
            } else {
                editorList
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh from Disk (⌘R)")
                .disabled(!viewModel.canRefresh)

                Button {
                    viewModel.save()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save (⌘S)")
                .disabled(!viewModel.canSave)

                Button {
                    viewModel.showSkippedSlides.toggle()
                } label: {
                    Image(systemName: viewModel.showSkippedSlides ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .help(viewModel.showSkippedSlides ? "Hide Skipped Slides" : "Show Skipped Slides")
                .disabled(!viewModel.hasOpenDocument || viewModel.isBusy)
            }
        }
        .confirmationDialog(
            "You have unsaved edits.",
            isPresented: $viewModel.isUnsavedDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Save") { viewModel.resolveUnsavedDialog(.save) }
            Button("Discard Changes", role: .destructive) { viewModel.resolveUnsavedDialog(.discard) }
            Button("Cancel", role: .cancel) { viewModel.resolveUnsavedDialog(.cancel) }
        } message: {
            Text("Save before continuing?")
        }
        .confirmationDialog(
            "The file changed on disk.",
            isPresented: $viewModel.isConflictDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Try Merge") { viewModel.handleConflictAction(.tryMerge) }
            Button("Refresh") { viewModel.handleConflictAction(.refresh) }
            Button("Overwrite") { viewModel.handleConflictAction(.overwrite) }
            Button("Cancel", role: .cancel) { viewModel.handleConflictAction(.cancel) }
        } message: {
            Text(viewModel.conflictMessage)
        }
        .confirmationDialog(
            "The file was updated on disk.",
            isPresented: $viewModel.isExternalUpdateAlertPresented,
            titleVisibility: .visible
        ) {
            Button("Refresh") { viewModel.handleExternalUpdateChoice(.refresh) }
            Button("Later", role: .cancel) { viewModel.handleExternalUpdateChoice(.later) }
        } message: {
            Text("Do you want to refresh and load the latest version?")
        }
        .alert(
            "Error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { shouldShow in
                    if !shouldShow {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .overlay {
            if viewModel.isBusy {
                ProgressView(viewModel.statusMessage)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if viewModel.isUITestMode {
                UITestDiagnosticsPanel(viewModel: viewModel)
                    .padding(12)
            }
        }
        .background(
            WindowCloseBridge(
                viewModel: viewModel,
                title: viewModel.fileURL?.lastPathComponent ?? "Keynote Outliner",
                subtitle: viewModel.statusMessage
            )
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("Open a Keynote file to inspect presenter notes.")
                .foregroundStyle(.secondary)
            Button("Open Keynote File…") {
                viewModel.openFile()
            }
            .disabled(viewModel.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(viewModel.visibleRowIndices, id: \.self) { index in
                        SlideRowView(
                            row: $viewModel.rows[index],
                            noteFontSize: viewModel.noteFontSize,
                            findController: findController
                        )
                        .id(viewModel.rows[index].id)
                        .background(
                            RowMinYReporter(rowID: viewModel.rows[index].id)
                        )
                    }
                }
                .padding(16)
                .background(
                    OuterScrollViewBridge { scrollView in
                        zoomCoordinator.register(scrollView: scrollView)
                        findController.registerFindBarContainer(scrollView)
                    }
                    .frame(width: 0, height: 0)
                )
            }
            .background(
                FindControllerConfigurator(
                    findController: findController,
                    snapshots: visibleSearchableRows,
                    proxy: proxy
                )
            )
        }
        .coordinateSpace(name: Self.editorScrollCoordinateSpace)
        .onPreferenceChange(RowMinYPreferenceKey.self) { values in
            zoomCoordinator.updateRowMinY(values)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var visibleSearchableRows: [SearchableRowSnapshot] {
        viewModel.visibleRowIndices.map { index in
            SearchableRowSnapshot(
                rowID: viewModel.rows[index].id,
                text: viewModel.rows[index].editedNoteText,
                isEditable: viewModel.rows[index].isEditable
            )
        }
    }
}

private struct SlideRowView: View {
    @Binding var row: SlideRowModel
    var noteFontSize: CGFloat
    var findController: NotesFindController
    @State private var editorHeight: CGFloat = 120

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                Text(row.keynoteIndex.map(String.init) ?? "")
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
                    .padding(.bottom, 4)

                ThumbnailCell(path: row.thumbnailPath)
                    .frame(width: 230, height: 130)
            }

            VStack(alignment: .leading, spacing: 8) {
                if row.isEditable {
                    AutoSizingNoteEditor(
                        rowID: row.id,
                        text: $row.editedNoteText,
                        fontSize: noteFontSize,
                        minHeight: editorMinHeight,
                        measuredHeight: $editorHeight,
                        findController: findController,
                        accessibilityIdentifier: "notes.editor.\(row.id)",
                        accessibilityLabel: rowAccessibilityLabel
                    )
                        .frame(height: max(editorMinHeight, editorHeight))
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        .overlay(alignment: .topTrailing) {
                            if row.isSkipped || row.isDirty {
                                HStack(spacing: 8) {
                                    if row.isSkipped {
                                        SlideRowTag(text: "Skipped", tint: .orange)
                                    }
                                    if row.isDirty {
                                        Text("Edited")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    }
                                }
                                .padding(8)
                            }
                        }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This slide can't be edited.")
                            .font(.body.weight(.semibold))
                        if let issue = issueDescription {
                            Text(issue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 8) {
                            if row.isSkipped {
                                SlideRowTag(text: "Skipped", tint: .orange)
                            }
                            SlideRowTag(text: "Read-Only", tint: .secondary)
                        }
                        .padding(8)
                    }
                }
            }
            .onAppear {
                editorHeight = max(editorHeight, editorMinHeight)
            }
            .onChange(of: noteFontSize) { _, _ in
                editorHeight = max(editorHeight, editorMinHeight)
            }
        }
        .accessibilityIdentifier("notes.row.\(row.id)")
    }

    private var issueDescription: String? {
        switch row.loadIssue {
        case "missing-slide-archive":
            return "Slide archive is missing from this file."
        case "slide-archive-decode-failed":
            return "Slide archive could not be decoded."
        case nil:
            return nil
        default:
            return "Slide archive is unavailable."
        }
    }

    private var editorMinHeight: CGFloat {
        max(120, 120 * (noteFontSize / OutlinerViewModel.defaultNoteFontSize))
    }

    private var rowAccessibilityLabel: String {
        if let keynoteIndex = row.keynoteIndex {
            return "Slide \(keynoteIndex) notes editor"
        }
        return "Slide \(row.index) notes editor"
    }
}

private struct AutoSizingNoteEditor: NSViewRepresentable {
    var rowID: SlideRowModel.ID
    @Binding var text: String
    var fontSize: CGFloat
    var minHeight: CGFloat
    @Binding var measuredHeight: CGFloat
    var findController: NotesFindController
    var accessibilityIdentifier: String
    var accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rowID: rowID,
            text: $text,
            measuredHeight: $measuredHeight,
            minHeight: minHeight,
            findController: findController
        )
    }

    func makeNSView(context: Context) -> GrowingNoteTextView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        let textView = GrowingNoteTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize.zero
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.string = text
        textView.searchRowID = rowID
        textView.notesFindController = findController
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.onFrameSizeDidChange = { [weak coordinator = context.coordinator] in
            coordinator?.recalculateHeight()
        }

        context.coordinator.textView = textView
        findController.registerTextView(textView, rowID: rowID)
        context.coordinator.recalculateHeight()
        return textView
    }

    func updateNSView(_ nsView: GrowingNoteTextView, context: Context) {
        context.coordinator.updateBindings(
            rowID: rowID,
            text: $text,
            measuredHeight: $measuredHeight,
            minHeight: minHeight,
            findController: findController
        )
        nsView.searchRowID = rowID
        nsView.notesFindController = findController
        nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        nsView.setAccessibilityLabel(accessibilityLabel)
        findController.registerTextView(nsView, rowID: rowID)

        if nsView.string != text {
            context.coordinator.isApplyingExternalText = true
            nsView.string = text
            context.coordinator.isApplyingExternalText = false
            findController.handleVisibleTextChange(
                rowID: rowID,
                text: text,
                selectedRange: nsView.selectedRange()
            )
        }

        if nsView.font?.pointSize != fontSize {
            nsView.font = NSFont.systemFont(ofSize: fontSize)
        }

        context.coordinator.recalculateHeight()
    }

    static func dismantleNSView(_ nsView: GrowingNoteTextView, coordinator: Coordinator) {
        guard let rowID = nsView.searchRowID else { return }
        coordinator.findController.unregisterTextView(nsView, rowID: rowID)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var rowID: SlideRowModel.ID
        var text: Binding<String>
        var measuredHeight: Binding<CGFloat>
        var minHeight: CGFloat
        var findController: NotesFindController
        weak var textView: GrowingNoteTextView?
        var isApplyingExternalText = false

        init(
            rowID: SlideRowModel.ID,
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            minHeight: CGFloat,
            findController: NotesFindController
        ) {
            self.rowID = rowID
            self.text = text
            self.measuredHeight = measuredHeight
            self.minHeight = minHeight
            self.findController = findController
        }

        func updateBindings(
            rowID: SlideRowModel.ID,
            text: Binding<String>,
            measuredHeight: Binding<CGFloat>,
            minHeight: CGFloat,
            findController: NotesFindController
        ) {
            self.rowID = rowID
            self.text = text
            self.measuredHeight = measuredHeight
            self.minHeight = minHeight
            self.findController = findController
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if !isApplyingExternalText, text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            findController.handleVisibleTextChange(
                rowID: rowID,
                text: textView.string,
                selectedRange: textView.selectedRange()
            )
            recalculateHeight()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            findController.handleSelectionChange(
                rowID: rowID,
                localRange: textView.selectedRange()
            )
        }

        func recalculateHeight() {
            guard
                let textView,
                let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else {
                return
            }

            let width = max(textView.bounds.width - (textView.textContainerInset.width * 2), 1)
            if abs(textContainer.containerSize.width - width) > 0.5 {
                textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let calculatedHeight = ceil(usedRect.height + (textView.textContainerInset.height * 2))
            let targetHeight = max(minHeight, calculatedHeight)

            guard abs(measuredHeight.wrappedValue - targetHeight) > 0.5 else { return }
            DispatchQueue.main.async { [measuredHeight] in
                measuredHeight.wrappedValue = targetHeight
            }
        }
    }
}

final class GrowingNoteTextView: NSTextView {
    var onFrameSizeDidChange: (() -> Void)?
    weak var notesFindController: NotesFindController?
    var searchRowID: SlideRowModel.ID?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onFrameSizeDidChange?()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            notesFindController?.handleTextViewBecameFirstResponder(self)
        }
        return didBecomeFirstResponder
    }

    override func performTextFinderAction(_ sender: Any?) {
        if notesFindController?.performAction(for: sender) == true {
            return
        }
        super.performTextFinderAction(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSResponder.performTextFinderAction(_:)),
           let result = notesFindController?.validateAction(for: item)
        {
            return result
        }
        return super.validateUserInterfaceItem(item)
    }
}

private struct RowMinYPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct RowMinYReporter: View {
    var rowID: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: RowMinYPreferenceKey.self,
                value: [rowID: geometry.frame(in: .named(ContentView.editorScrollCoordinateSpace)).minY]
            )
        }
    }
}

private struct OuterScrollViewBridge: NSViewRepresentable {
    var onResolve: (NSScrollView) -> Void

    func makeNSView(context: Context) -> FinderView {
        FinderView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: FinderView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfPossible()
    }

    final class FinderView: NSView {
        var onResolve: ((NSScrollView) -> Void)?
        private weak var lastResolvedScrollView: NSScrollView?

        init(onResolve: ((NSScrollView) -> Void)?) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfPossible()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveIfPossible()
        }

        override func layout() {
            super.layout()
            resolveIfPossible()
        }

        func resolveIfPossible() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let scrollView = self.enclosingScrollView else { return }
                guard self.lastResolvedScrollView !== scrollView else { return }
                self.lastResolvedScrollView = scrollView
                self.onResolve?(scrollView)
            }
        }
    }
}

private struct FindControllerConfigurator: View {
    var findController: NotesFindController
    var snapshots: [SearchableRowSnapshot]
    var proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onAppear(perform: synchronize)
            .onChange(of: snapshots) { _, _ in
                synchronize()
            }
    }

    private func synchronize() {
        findController.setScrollToRow { rowID in
            let transaction = Transaction(animation: nil)
            withTransaction(transaction) {
                proxy.scrollTo(rowID, anchor: .center)
            }
        }
        findController.updateSearchableRows(snapshots)
    }
}

private struct UITestDiagnosticsPanel: View {
    @Bindable var viewModel: OutlinerViewModel

    var body: some View {
        HStack(spacing: 1) {
            UITestDiagnosticValue(
                identifier: "uiTest.statusMessage",
                value: viewModel.statusMessage
            )
            UITestDiagnosticValue(
                identifier: "uiTest.find.selectionSignature",
                value: viewModel.uiTestFindSelectionSignature
            )
            UITestDiagnosticValue(
                identifier: "uiTest.find.pendingRevealRowID",
                value: viewModel.uiTestFindPendingRevealRowID
            )
        }
        .allowsHitTesting(false)
    }
}

private struct UITestDiagnosticValue: View {
    var identifier: String
    var value: String

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityIdentifier(identifier)
            .accessibilityValue(Text(value))
    }
}

private struct SlideRowTag: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

private struct ThumbnailCell: View {
    var path: String?

    var body: some View {
        Group {
            if
                let path,
                let image = NSImage(contentsOfFile: path)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.04))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("No Thumbnail")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

#Preview {
    ContentView(
        viewModel: OutlinerViewModel(),
        zoomCoordinator: NotesZoomCoordinator(),
        findController: NotesFindController()
    )
        .frame(width: 1000, height: 700)
}
