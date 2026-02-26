//
//  OutlinerViewModel.swift
//  Keynote Outliner
//

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class OutlinerViewModel {
    enum PendingAction {
        case openPanel
        case openRecent(URL)
        case refresh
        case closeWindow
        case quitApplication
    }

    enum UnsavedChoice {
        case save
        case discard
        case cancel
    }

    enum ExternalUpdateChoice {
        case refresh
        case later
    }

    private struct PendingSaveContext {
        var inputURL: URL
        var outputURL: URL
        var continueWith: PendingAction?
        var setOutputAsCurrentFile: Bool
        var backupSourceURL: URL?
    }

    private struct ObservedFileState {
        var mtime: Double
        var size: Int
        var inode: UInt64?

        func differs(from other: Self) -> Bool {
            if size != other.size {
                return true
            }
            if abs(mtime - other.mtime) > 0.0005 {
                return true
            }
            if let inode, let otherInode = other.inode, inode != otherInode {
                return true
            }
            return false
        }
    }

    private enum KeynoteReloadResult {
        case reloaded
        case notOpen
        case skippedDueToUnsavedKeynoteChanges
        case failed(String)
    }

    private enum BackupError: LocalizedError {
        case sourceMissing(String)
        case cannotRotate(String)
        case cannotCopy(String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let path):
                return "Backup source file missing: \(path)"
            case .cannotRotate(let message):
                return "Failed to rotate backups: \(message)"
            case .cannotCopy(let message):
                return "Failed to create backup copy: \(message)"
            }
        }
    }

    private enum PersistenceKeys {
        static let recentFiles = "KeynoteOutlinerRecentFiles"
        static let lastOpenedFile = "KeynoteOutlinerLastOpenedFile"
        static let maxRecents = 12
    }

    private(set) var fileURL: URL?
    var rows: [SlideRowModel] = []
    var showSkippedSlides = false
    private(set) var recentFiles: [URL] = []
    private(set) var isBusy = false {
        didSet {
            guard oldValue, !isBusy else { return }
            resumeDeferredExternalOpenIfNeeded()
        }
    }
    var statusMessage = "Open a Keynote file to begin."
    var errorMessage: String?

    var isUnsavedDialogPresented = false
    var isConflictDialogPresented = false
    var isExternalUpdateAlertPresented = false
    var conflictMessage = ""

    var hasOpenDocument: Bool { fileURL != nil }
    var hasUnsavedChanges: Bool { rows.contains { $0.isEditable && $0.isDirty } }
    var canRefresh: Bool { hasOpenDocument && !isBusy && hasExternalFileUpdate }
    var canSave: Bool { hasOpenDocument && !isBusy && hasUnsavedChanges }
    var canCopyAllNotes: Bool { !isBusy && !visibleRowIndices.isEmpty }
    var visibleRowIndices: [Int] {
        guard !showSkippedSlides else { return Array(rows.indices) }
        return rows.indices.filter { !rows[$0].isSkipped }
    }

    private var snapshot: DeckSnapshot?
    private var pendingAction: PendingAction?
    private var pendingWindowCloseAction: (() -> Void)?
    private var pendingSaveContext: PendingSaveContext?
    private var latestConflicts: [SaveConflict] = []
    private var allowImmediateTermination = false
    private(set) var hasExternalFileUpdate = false
    private var monitoredFileURL: URL?
    private var monitoredFileState: ObservedFileState?
    private var hasPromptedForExternalUpdate = false
    private var fileMonitorTask: Task<Void, Never>?
    private var deferredExternalOpenURL: URL?

    private let backend = KeynoteBackendClient()

    init() {
        startFileMonitor()
        loadPersistedRecents()
        Task { [weak self] in
            self?.reopenLastOpenedFileIfAvailable()
        }
    }

    func openFile() {
        guard !isBusy else { return }
        if hasUnsavedChanges {
            pendingWindowCloseAction = nil
            pendingAction = .openPanel
            isUnsavedDialogPresented = true
            return
        }
        openPanelAndLoad()
    }

    func openRecent(_ url: URL) {
        guard !isBusy else { return }
        if hasUnsavedChanges {
            pendingWindowCloseAction = nil
            pendingAction = .openRecent(url)
            isUnsavedDialogPresented = true
            return
        }
        loadDocument(from: url)
    }

    @discardableResult
    func handleExternalOpenRequest(_ urls: [URL]) -> Bool {
        guard
            let url = urls
                .map(\.standardizedFileURL)
                .first(where: isSupportedKeynoteURL)
        else {
            return false
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "Unable to open \(url.lastPathComponent)."
            errorMessage = "The selected file no longer exists on disk."
            return false
        }

        if isBusy {
            deferredExternalOpenURL = url
            statusMessage = "Queued \(url.lastPathComponent) to open next."
            return true
        }

        openRecent(url)
        return true
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
        guard hasExternalFileUpdate else {
            statusMessage = "Already up to date."
            return
        }
        if hasUnsavedChanges {
            pendingWindowCloseAction = nil
            pendingAction = .refresh
            isUnsavedDialogPresented = true
            return
        }
        refreshFromDisk()
    }

    func handleExternalUpdateChoice(_ choice: ExternalUpdateChoice) {
        isExternalUpdateAlertPresented = false
        switch choice {
        case .refresh:
            refresh()
        case .later:
            break
        }
    }

    func save() {
        guard !isBusy else { return }
        guard let currentURL = fileURL else {
            statusMessage = "Open a Keynote file first."
            return
        }
        guard hasUnsavedChanges else { return }
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

    func copyAllVisibleNotesToClipboard() {
        guard !isBusy else { return }

        let indices = visibleRowIndices
        guard !indices.isEmpty else {
            statusMessage = "No visible notes to copy."
            return
        }

        let notes = indices.map { rows[$0].editedNoteText }.joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.setString(notes, forType: .string) else {
            statusMessage = "Failed to copy notes."
            errorMessage = "The clipboard could not be updated."
            return
        }

        let count = indices.count
        statusMessage = "Copied notes for \(count) visible slide\(count == 1 ? "" : "s")."
        errorMessage = nil
    }

    func interceptWindowCloseIfNeeded(closeAction: @escaping () -> Void) -> Bool {
        guard !isBusy else {
            statusMessage = "Please wait for the current operation to finish."
            return true
        }
        if hasUnsavedChanges {
            pendingWindowCloseAction = closeAction
            pendingAction = .closeWindow
            isUnsavedDialogPresented = true
            return true
        }
        return false
    }

    func requestQuitApplicationFromUser() {
        guard !isBusy else {
            statusMessage = "Please wait for the current operation to finish."
            return
        }
        if hasUnsavedChanges {
            pendingWindowCloseAction = nil
            pendingAction = .quitApplication
            isUnsavedDialogPresented = true
            return
        }
        performImmediateQuit()
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if allowImmediateTermination {
            allowImmediateTermination = false
            return .terminateNow
        }
        if isBusy {
            statusMessage = "Please wait for the current operation to finish."
            return .terminateCancel
        }
        if hasUnsavedChanges {
            pendingWindowCloseAction = nil
            pendingAction = .quitApplication
            isUnsavedDialogPresented = true
            return .terminateCancel
        }
        return .terminateNow
    }

    func resolveUnsavedDialog(_ choice: UnsavedChoice) {
        defer {
            isUnsavedDialogPresented = false
            if choice != .save {
                pendingAction = nil
                pendingWindowCloseAction = nil
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
            pendingWindowCloseAction = nil
            pendingSaveContext = nil
            refreshFromDisk()
        case .cancel:
            statusMessage = "Save cancelled due to conflict."
            pendingAction = nil
            pendingWindowCloseAction = nil
            pendingSaveContext = nil
        }
    }

    func setEditedText(_ text: String, for id: SlideRowModel.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        guard rows[index].isEditable else { return }
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
        case .closeWindow:
            let closeAction = pendingWindowCloseAction
            pendingWindowCloseAction = nil
            closeAction?()
        case .quitApplication:
            performImmediateQuit()
        }
    }

    private func performImmediateQuit() {
        allowImmediateTermination = true
        NSApplication.shared.terminate(nil)
    }

    private func openPanelAndLoad() {
        guard let selectedURL = runOpenPanel() else { return }
        loadDocument(from: selectedURL)
    }

    private func resumeDeferredExternalOpenIfNeeded() {
        guard let deferredExternalOpenURL else { return }
        self.deferredExternalOpenURL = nil
        openRecent(deferredExternalOpenURL)
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
                    self.updateMonitorBaseline(from: loaded.file)
                    self.pendingAction = nil
                    self.pendingWindowCloseAction = nil
                    self.pendingSaveContext = nil
                    self.latestConflicts = []
                    let skippedCount = loaded.slides.filter(\.isSkipped).count
                    let unavailableCount = loaded.slides.filter { !$0.isEditable }.count
                    var statusParts = ["Loaded \(loaded.slides.count) slides from \(url.lastPathComponent)."]
                    if skippedCount > 0 {
                        statusParts.append("\(skippedCount) skipped slide\(skippedCount == 1 ? "" : "s") hidden.")
                    }
                    if unavailableCount > 0 {
                        statusParts.append("\(unavailableCount) slide\(unavailableCount == 1 ? "" : "s") cannot be edited.")
                    }
                    self.statusMessage = statusParts.joined(separator: " ")
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

        var backupSourceURL: URL?
        let candidate = backupTargetIfNeeded(inputURL: inputURL, outputURL: outputURL)
        if let candidate {
            do {
                try createRollingBackups(for: candidate)
                backupSourceURL = candidate
            } catch {
                statusMessage = "Save aborted: backup failed."
                errorMessage = error.localizedDescription
                return
            }
        }

        let state = SaveStatePayload(
            baseFile: snapshot.file,
            rows: rows.filter(\.isEditable).map {
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
            setOutputAsCurrentFile: setOutputAsCurrentFile,
            backupSourceURL: backupSourceURL
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
            var updatedFingerprint: DeckFileFingerprint?
            if var snapshot {
                if let updatedFile = response.file {
                    snapshot.file = updatedFile
                } else if let url = fileURL {
                    snapshot.file.url = url.path
                }
                snapshot.slides = rows
                self.snapshot = snapshot
                updatedFingerprint = snapshot.file
            } else if let updatedFile = response.file {
                updatedFingerprint = updatedFile
            }
            if let updatedFingerprint {
                updateMonitorBaseline(from: updatedFingerprint)
            }
            let count = response.savedRows ?? 0
            statusMessage = "Saved \(count) edited slide\(count == 1 ? "" : "s")."
            if context.backupSourceURL != nil {
                statusMessage += " Backup updated."
            }
            pendingSaveContext = nil
            isBusy = false

            let savedURL = context.outputURL
            Task {
                let reloadResult = await Self.reloadKeynoteDocumentIfOpen(savedURL)
                await MainActor.run {
                    switch reloadResult {
                    case .reloaded:
                        self.statusMessage += " Reloaded in Keynote."
                    case .notOpen:
                        break
                    case .skippedDueToUnsavedKeynoteChanges:
                        self.statusMessage += " Keynote file has unsaved changes; skipped reload."
                    case .failed(let message):
                        self.statusMessage += " Keynote reload failed (\(message))."
                    }
                }
            }

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
            hasExternalFileUpdate = true
            hasPromptedForExternalUpdate = true
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

    private func isSupportedKeynoteURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return url.pathExtension.caseInsensitiveCompare("key") == .orderedSame
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

    private func startFileMonitor() {
        fileMonitorTask?.cancel()
        fileMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.pollForExternalFileUpdates()
            }
        }
    }

    private func pollForExternalFileUpdates() {
        guard !isBusy else { return }
        guard let monitoredFileURL, let monitoredFileState else { return }

        if hasExternalFileUpdate {
            presentExternalUpdateAlertIfNeeded()
            return
        }

        guard let current = Self.readObservedFileState(at: monitoredFileURL) else {
            markExternalFileUpdateDetected(message: "The file was moved or removed on disk.")
            return
        }

        if current.differs(from: monitoredFileState) {
            markExternalFileUpdateDetected(message: "The file was updated on disk.")
        }
    }

    private func updateMonitorBaseline(from fingerprint: DeckFileFingerprint) {
        let normalizedURL = URL(fileURLWithPath: fingerprint.url).standardizedFileURL
        monitoredFileURL = normalizedURL
        monitoredFileState =
            Self.readObservedFileState(at: normalizedURL)
            ?? ObservedFileState(mtime: fingerprint.mtime, size: fingerprint.size, inode: nil)
        hasExternalFileUpdate = false
        hasPromptedForExternalUpdate = false
        isExternalUpdateAlertPresented = false
    }

    private func markExternalFileUpdateDetected(message: String) {
        guard !hasExternalFileUpdate else {
            presentExternalUpdateAlertIfNeeded()
            return
        }
        hasExternalFileUpdate = true
        hasPromptedForExternalUpdate = false
        statusMessage = message
        presentExternalUpdateAlertIfNeeded()
    }

    private func presentExternalUpdateAlertIfNeeded() {
        guard hasExternalFileUpdate else { return }
        guard !hasPromptedForExternalUpdate else { return }
        guard !isBusy else { return }
        guard !isUnsavedDialogPresented else { return }
        guard !isConflictDialogPresented else { return }
        isExternalUpdateAlertPresented = true
        hasPromptedForExternalUpdate = true
    }

    private static func readObservedFileState(at url: URL) -> ObservedFileState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        guard let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return ObservedFileState(
            mtime: modified.timeIntervalSince1970,
            size: size,
            inode: inode
        )
    }

    private func backupTargetIfNeeded(inputURL: URL, outputURL: URL) -> URL? {
        let fm = FileManager.default
        let input = inputURL.standardizedFileURL
        let output = outputURL.standardizedFileURL
        if input.path == output.path {
            return input
        }
        if fm.fileExists(atPath: output.path) {
            return output
        }
        return nil
    }

    private func backupURL(for originalURL: URL, generation: Int) -> URL {
        let directory = originalURL.deletingLastPathComponent()
        let ext = originalURL.pathExtension.isEmpty ? "key" : originalURL.pathExtension
        let stem = originalURL.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(stem).backup\(generation)")
            .appendingPathExtension(ext)
    }

    private func createRollingBackups(for sourceURL: URL) throws {
        let fm = FileManager.default
        let source = sourceURL.standardizedFileURL
        guard fm.fileExists(atPath: source.path) else {
            throw BackupError.sourceMissing(source.path)
        }

        let backup1 = backupURL(for: source, generation: 1)
        let backup2 = backupURL(for: source, generation: 2)

        do {
            if fm.fileExists(atPath: backup2.path) {
                try fm.removeItem(at: backup2)
            }
            if fm.fileExists(atPath: backup1.path) {
                try fm.moveItem(at: backup1, to: backup2)
            }
        } catch {
            throw BackupError.cannotRotate(error.localizedDescription)
        }

        do {
            try fm.copyItem(at: source, to: backup1)
        } catch {
            throw BackupError.cannotCopy(error.localizedDescription)
        }
    }

    private static func reloadKeynoteDocumentIfOpen(_ url: URL) async -> KeynoteReloadResult {
        await Task.detached(priority: .utility) {
            let script = """
            on run argv
                set targetPath to item 1 of argv
                tell application "System Events"
                    set runningApps to name of every process
                end tell
                if runningApps does not contain "Keynote" then
                    return "not-open"
                end if
                tell application "Keynote"
                    set targetDoc to missing value
                    repeat with d in documents
                        set docPath to POSIX path of (file of d as alias)
                        if docPath is targetPath then
                            set targetDoc to d
                            exit repeat
                        end if
                    end repeat
                    if targetDoc is missing value then
                        return "not-open"
                    end if
                    if modified of targetDoc then
                        return "dirty"
                    end if
                    close targetDoc saving no
                    open POSIX file targetPath
                    return "reloaded"
                end tell
            end run
            """

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-", url.path]
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                return .failed(error.localizedDescription)
            }

            if let data = script.data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            stdin.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus != 0 {
                return .failed(err.isEmpty ? "osascript exit \(process.terminationStatus)" : err)
            }

            switch out {
            case "reloaded":
                return .reloaded
            case "dirty":
                return .skippedDueToUnsavedKeynoteChanges
            case "not-open":
                return .notOpen
            default:
                return .failed(out.isEmpty ? "unknown result" : out)
            }
        }.value
    }
}
