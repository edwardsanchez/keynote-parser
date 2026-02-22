//
//  OutlinerViewModel.swift
//  Keynote Outliner
//

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class OutlinerViewModel: ObservableObject {
    enum PendingAction {
        case openPanel
        case openRecent(URL)
        case refresh
    }

    enum UnsavedChoice {
        case save
        case discard
        case cancel
    }

    private struct PendingSaveContext {
        var inputURL: URL
        var outputURL: URL
        var continueWith: PendingAction?
        var setOutputAsCurrentFile: Bool
    }

    private enum PersistenceKeys {
        static let recentFiles = "KeynoteOutlinerRecentFiles"
        static let lastOpenedFile = "KeynoteOutlinerLastOpenedFile"
        static let maxRecents = 12
    }

    @Published private(set) var fileURL: URL?
    @Published var rows: [SlideRowModel] = []
    @Published private(set) var recentFiles: [URL] = []
    @Published private(set) var isBusy = false
    @Published var statusMessage = "Open a Keynote file to begin."
    @Published var errorMessage: String?

    @Published var isUnsavedDialogPresented = false
    @Published var isConflictDialogPresented = false
    @Published var conflictMessage = ""

    var hasOpenDocument: Bool { fileURL != nil }
    var hasUnsavedChanges: Bool { rows.contains(where: \.isDirty) }

    private var snapshot: DeckSnapshot?
    private var pendingAction: PendingAction?
    private var pendingSaveContext: PendingSaveContext?
    private var latestConflicts: [SaveConflict] = []

    private let backend = KeynoteBackendClient()

    init() {
        loadPersistedRecents()
        Task { [weak self] in
            self?.reopenLastOpenedFileIfAvailable()
        }
    }

    func openFile() {
        guard !isBusy else { return }
        if hasUnsavedChanges {
            pendingAction = .openPanel
            isUnsavedDialogPresented = true
            return
        }
        openPanelAndLoad()
    }

    func openRecent(_ url: URL) {
        guard !isBusy else { return }
        if hasUnsavedChanges {
            pendingAction = .openRecent(url)
            isUnsavedDialogPresented = true
            return
        }
        loadDocument(from: url)
    }

    func clearRecents() {
        recentFiles = []
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: PersistenceKeys.recentFiles)
    }

    func refresh() {
        guard !isBusy else { return }
        guard fileURL != nil else {
            statusMessage = "Open a Keynote file first."
            return
        }
        if hasUnsavedChanges {
            pendingAction = .refresh
            isUnsavedDialogPresented = true
            return
        }
        refreshFromDisk()
    }

    func save() {
        guard !isBusy else { return }
        guard let currentURL = fileURL else {
            statusMessage = "Open a Keynote file first."
            return
        }
        beginSave(
            inputURL: currentURL,
            outputURL: currentURL,
            mode: .strict,
            continueWith: nil,
            setOutputAsCurrentFile: true
        )
    }

    func saveAs() {
        guard !isBusy else { return }
        guard let currentURL = fileURL else {
            statusMessage = "Open a Keynote file first."
            return
        }
        guard let destinationURL = runSavePanel(suggestedFrom: currentURL) else {
            return
        }
        beginSave(
            inputURL: currentURL,
            outputURL: destinationURL,
            mode: .strict,
            continueWith: nil,
            setOutputAsCurrentFile: true
        )
    }

    func resolveUnsavedDialog(_ choice: UnsavedChoice) {
        defer {
            isUnsavedDialogPresented = false
            if choice != .save {
                pendingAction = nil
            }
        }
        guard let action = pendingAction else { return }

        switch choice {
        case .save:
            guard let currentURL = fileURL else {
                executePendingAction(action)
                return
            }
            beginSave(
                inputURL: currentURL,
                outputURL: currentURL,
                mode: .strict,
                continueWith: action,
                setOutputAsCurrentFile: true
            )
        case .discard:
            executePendingAction(action)
        case .cancel:
            statusMessage = "Action cancelled."
        }
    }

    func handleConflictAction(_ action: ConflictAction) {
        let context = pendingSaveContext
        isConflictDialogPresented = false

        switch action {
        case .tryMerge:
            guard let context else { return }
            beginSave(
                inputURL: context.inputURL,
                outputURL: context.outputURL,
                mode: .merge,
                continueWith: context.continueWith,
                setOutputAsCurrentFile: context.setOutputAsCurrentFile
            )
        case .overwrite:
            guard let context else { return }
            beginSave(
                inputURL: context.inputURL,
                outputURL: context.outputURL,
                mode: .overwrite,
                continueWith: context.continueWith,
                setOutputAsCurrentFile: context.setOutputAsCurrentFile
            )
        case .refresh:
            pendingAction = nil
            pendingSaveContext = nil
            refreshFromDisk()
        case .cancel:
            statusMessage = "Save cancelled due to conflict."
            pendingAction = nil
            pendingSaveContext = nil
        }
    }

    func setEditedText(_ text: String, for id: SlideRowModel.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].editedNoteText = text
    }

    private func executePendingAction(_ action: PendingAction) {
        switch action {
        case .openPanel:
            openPanelAndLoad()
        case .openRecent(let url):
            loadDocument(from: url)
        case .refresh:
            refreshFromDisk()
        }
    }

    private func openPanelAndLoad() {
        guard let selectedURL = runOpenPanel() else { return }
        loadDocument(from: selectedURL)
    }

    private func refreshFromDisk() {
        guard let currentURL = fileURL else { return }
        loadDocument(from: currentURL)
    }

    private func loadDocument(from url: URL) {
        isBusy = true
        statusMessage = "Loading \(url.lastPathComponent)…"
        errorMessage = nil

        let cacheURL = Self.cacheDirectoryURL()
        Task {
            do {
                let loaded = try await backend.load(input: url, cacheDir: cacheURL)
                await MainActor.run {
                    self.snapshot = loaded
                    self.rows = loaded.slides
                    self.setCurrentFile(URL(fileURLWithPath: loaded.file.url))
                    self.pendingAction = nil
                    self.pendingSaveContext = nil
                    self.latestConflicts = []
                    self.statusMessage = "Loaded \(loaded.slides.count) slides from \(url.lastPathComponent)."
                    self.isBusy = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Failed to load \(url.lastPathComponent)."
                    self.errorMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    private func beginSave(
        inputURL: URL,
        outputURL: URL,
        mode: SaveMode,
        continueWith: PendingAction?,
        setOutputAsCurrentFile: Bool
    ) {
        guard let snapshot else {
            statusMessage = "Nothing to save."
            return
        }

        let state = SaveStatePayload(
            baseFile: snapshot.file,
            rows: rows.map {
                SaveRowState(
                    slideId: $0.slideId,
                    baseText: $0.baseNoteText,
                    editedText: $0.editedNoteText
                )
            }
        )

        isBusy = true
        statusMessage = "Saving \(outputURL.lastPathComponent)…"
        errorMessage = nil

        let context = PendingSaveContext(
            inputURL: inputURL,
            outputURL: outputURL,
            continueWith: continueWith,
            setOutputAsCurrentFile: setOutputAsCurrentFile
        )
        pendingSaveContext = context
        let cacheURL = Self.cacheDirectoryURL()

        Task {
            do {
                let response = try await backend.save(
                    input: inputURL,
                    output: outputURL,
                    state: state,
                    mode: mode,
                    cacheDir: cacheURL
                )
                await MainActor.run {
                    self.handleSaveResponse(response, context: context)
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = "Save failed."
                    self.errorMessage = error.localizedDescription
                    self.isBusy = false
                }
            }
        }
    }

    private func handleSaveResponse(_ response: SaveResponse, context: PendingSaveContext) {
        switch response.status {
        case .saved:
            for index in rows.indices {
                rows[index].baseNoteText = rows[index].editedNoteText
            }
            if context.setOutputAsCurrentFile {
                setCurrentFile(context.outputURL)
            }
            if var snapshot {
                if let updatedFile = response.file {
                    snapshot.file = updatedFile
                } else if let url = fileURL {
                    snapshot.file.url = url.path
                }
                snapshot.slides = rows
                self.snapshot = snapshot
            }
            let count = response.savedRows ?? 0
            statusMessage = "Saved \(count) edited slide\(count == 1 ? "" : "s")."
            pendingSaveContext = nil
            isBusy = false

            if let action = context.continueWith {
                pendingAction = nil
                executePendingAction(action)
            }

        case .conflict:
            latestConflicts = response.conflicts ?? []
            let summary = summarizeConflicts(latestConflicts)
            let baseMessage = response.message ?? "File changed since load."
            conflictMessage = [baseMessage, summary].filter { !$0.isEmpty }.joined(separator: "\n")
            isConflictDialogPresented = true
            statusMessage = "Save conflict detected."
            isBusy = false

        case .error:
            statusMessage = "Save failed."
            errorMessage = response.error ?? response.message ?? "Unknown save error."
            isBusy = false
        }
    }

    private func summarizeConflicts(_ conflicts: [SaveConflict]) -> String {
        guard !conflicts.isEmpty else { return "" }
        let sorted = conflicts.sorted { $0.index < $1.index }
        let indices = sorted.prefix(6).map { "Slide \($0.index)" }.joined(separator: ", ")
        let suffix = conflicts.count > 6 ? "…" : ""
        return "Conflicts: \(indices)\(suffix)"
    }

    private func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let keynoteType = UTType(filenameExtension: "key") {
            panel.allowedContentTypes = [keynoteType]
        }
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runSavePanel(suggestedFrom sourceURL: URL) -> URL? {
        let panel = NSSavePanel()
        if let keynoteType = UTType(filenameExtension: "key") {
            panel.allowedContentTypes = [keynoteType]
        }
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.prompt = "Save"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func cacheDirectoryURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cache = root.appendingPathComponent("KeynoteOutliner", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return cache
    }

    private func setCurrentFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        fileURL = normalized
        addRecentFile(normalized)
        UserDefaults.standard.set(normalized.path, forKey: PersistenceKeys.lastOpenedFile)
    }

    private func addRecentFile(_ url: URL) {
        let normalized = url.standardizedFileURL
        recentFiles.removeAll { $0.standardizedFileURL.path == normalized.path }
        recentFiles.insert(normalized, at: 0)
        if recentFiles.count > PersistenceKeys.maxRecents {
            recentFiles = Array(recentFiles.prefix(PersistenceKeys.maxRecents))
        }
        persistRecents()
        NSDocumentController.shared.noteNewRecentDocumentURL(normalized)
    }

    private func persistRecents() {
        let paths = recentFiles.map(\.path)
        UserDefaults.standard.set(paths, forKey: PersistenceKeys.recentFiles)
    }

    private func loadPersistedRecents() {
        let defaults = UserDefaults.standard
        let rawPaths = defaults.stringArray(forKey: PersistenceKeys.recentFiles) ?? []
        let existing = rawPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        recentFiles = Array(existing.prefix(PersistenceKeys.maxRecents))
        persistRecents()
    }

    private func reopenLastOpenedFileIfAvailable() {
        guard fileURL == nil, rows.isEmpty else { return }
        guard let path = UserDefaults.standard.string(forKey: PersistenceKeys.lastOpenedFile) else {
            return
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: PersistenceKeys.lastOpenedFile)
            return
        }
        loadDocument(from: url)
    }
}
