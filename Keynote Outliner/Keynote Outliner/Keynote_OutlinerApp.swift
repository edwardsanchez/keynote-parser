//
//  Keynote_OutlinerApp.swift
//  Keynote Outliner
//

import AppKit
import SwiftUI

@MainActor
final class KeynoteOutlinerAppDelegate: NSObject, NSApplicationDelegate, NSUserInterfaceValidations {
    weak var viewModel: OutlinerViewModel? {
        didSet {
            flushPendingOpenRequestsIfNeeded()
        }
    }
    weak var findController: NotesFindController?

    private var pendingOpenURLs: [URL] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewModel?.applicationShouldTerminate() ?? .terminateNow
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleIncomingOpenRequests([URL(fileURLWithPath: filename)])
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let handled = handleIncomingOpenRequests(urls)
        sender.reply(toOpenOrPrint: handled ? .success : .failure)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = handleIncomingOpenRequests(urls)
    }

    @objc
    func performTextFinderAction(_ sender: Any?) {
        _ = findController?.performAction(for: sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(performTextFinderAction(_:)) else {
            return true
        }
        return findController?.validateAction(for: item) ?? false
    }

    private func handleIncomingOpenRequests(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        guard let viewModel else {
            pendingOpenURLs.append(contentsOf: urls)
            return true
        }
        return viewModel.handleExternalOpenRequest(urls)
    }

    private func flushPendingOpenRequestsIfNeeded() {
        guard let viewModel, !pendingOpenURLs.isEmpty else { return }
        let queued = pendingOpenURLs
        pendingOpenURLs.removeAll()
        _ = viewModel.handleExternalOpenRequest(queued)
    }
}

@main
struct Keynote_OutlinerApp: App {
    @NSApplicationDelegateAdaptor(KeynoteOutlinerAppDelegate.self) private var appDelegate
    @State private var viewModel = OutlinerViewModel()
    @State private var zoomCoordinator = NotesZoomCoordinator()
    @State private var findController = NotesFindController()

    var body: some Scene {
        WindowGroup {
            ContentView(
                viewModel: viewModel,
                zoomCoordinator: zoomCoordinator,
                findController: findController
            )
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    appDelegate.findController = findController
                    findController.configure(
                        applyEditedText: { text, rowID in
                            viewModel.setEditedText(text, for: rowID)
                        },
                        setStatusMessage: { message in
                            viewModel.statusMessage = message
                        },
                        updateDebugState: { selectedRowID, globalRange, pendingRevealRowID in
                            viewModel.updateFindDebugState(
                                selectedRowID: selectedRowID,
                                globalRange: globalRange,
                                pendingRevealRowID: pendingRevealRowID
                            )
                        }
                    )
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    viewModel.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(viewModel.isBusy)

                Menu("Open Recent") {
                    if viewModel.recentFiles.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(viewModel.recentFiles, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                viewModel.openRecent(url)
                            }
                            .help(url.path)
                            .disabled(viewModel.isBusy)
                        }
                        Divider()
                        Button("Clear Menu") {
                            viewModel.clearRecents()
                        }
                        .disabled(viewModel.isBusy)
                    }
                }
                .disabled(viewModel.isBusy)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    viewModel.save()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!viewModel.canSave)

                Button("Save As…") {
                    viewModel.saveAs()
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
                .disabled(!viewModel.hasOpenDocument || viewModel.isBusy)
            }

            CommandGroup(after: .pasteboard) {
                Menu("Find") {
                    Button("Find…") {
                        findController.performAction(.showFindInterface)
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    Button("Find and Replace…") {
                        findController.performAction(.showReplaceInterface)
                    }
                    .keyboardShortcut("f", modifiers: [.command, .option])

                    Button("Use Selection for Find") {
                        findController.performAction(.setSearchString)
                    }
                    .keyboardShortcut("e", modifiers: .command)

                    Divider()

                    Button("Find Next") {
                        findController.performAction(.nextMatch)
                    }
                    .keyboardShortcut("g", modifiers: .command)

                    Button("Find Previous") {
                        findController.performAction(.previousMatch)
                    }
                    .keyboardShortcut("G", modifiers: [.command, .shift])
                }
                .disabled(viewModel.visibleRowIndices.isEmpty)

                Divider()

                Button("Copy All Notes") {
                    viewModel.copyAllVisibleNotesToClipboard()
                }
                .disabled(!viewModel.canCopyAllNotes)
            }

            CommandGroup(after: .toolbar) {
                Button("Increase Note Font Size") {
                    zoomCoordinator.performZoom(.increase, viewModel: viewModel)
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(viewModel.rows.isEmpty)

                Button("Decrease Note Font Size") {
                    zoomCoordinator.performZoom(.decrease, viewModel: viewModel)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(viewModel.rows.isEmpty)
            }

            CommandMenu("Document") {
                Button("Refresh") {
                    viewModel.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!viewModel.canRefresh)
            }

            CommandGroup(replacing: .appTermination) {
                Button("Quit Keynote Outliner") {
                    viewModel.requestQuitApplicationFromUser()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
