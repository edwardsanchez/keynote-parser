//
//  Keynote_OutlinerApp.swift
//  Keynote Outliner
//

import SwiftUI

@main
struct Keynote_OutlinerApp: App {
    @StateObject private var viewModel = OutlinerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 640)
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
                .disabled(!viewModel.hasOpenDocument || viewModel.isBusy)

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
        }
    }
}
