//
//  Keynote_OutlinerApp.swift
//  Keynote Outliner
//

import AppKit
import SwiftUI

final class KeynoteOutlinerAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: OutlinerViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewModel?.applicationShouldTerminate() ?? .terminateNow
    }
}

@main
struct Keynote_OutlinerApp: App {
    @NSApplicationDelegateAdaptor(KeynoteOutlinerAppDelegate.self) private var appDelegate
    @State private var viewModel = OutlinerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    appDelegate.viewModel = viewModel
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

            CommandMenu("Document") {
                Button("Refresh") {
                    viewModel.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!viewModel.hasOpenDocument || viewModel.isBusy)
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
