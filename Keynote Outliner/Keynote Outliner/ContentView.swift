//
//  ContentView.swift
//  Keynote Outliner
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: OutlinerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
                .help("Refresh (⌘R)")
                .disabled(!viewModel.hasOpenDocument || viewModel.isBusy)

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
                    Image(systemName: viewModel.showSkippedSlides ? "eye.slash" : "eye")
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
        .background(WindowCloseBridge(viewModel: viewModel))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.fileURL?.lastPathComponent ?? "No file open")
                .font(.headline)
            Text(viewModel.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.visibleRowIndices, id: \.self) { index in
                    SlideRowView(row: $viewModel.rows[index])
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct SlideRowView: View {
    @Binding var row: SlideRowModel

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
                    TextEditor(text: $row.editedNoteText)
                        .font(.body)
                        .frame(minHeight: 120)
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
        }
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
    ContentView(viewModel: OutlinerViewModel())
        .frame(width: 1000, height: 700)
}
