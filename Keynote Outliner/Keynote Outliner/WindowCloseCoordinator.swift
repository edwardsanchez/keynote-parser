//
//  WindowCloseCoordinator.swift
//  Keynote Outliner
//

import AppKit
import SwiftUI

final class WindowCloseCoordinator: NSObject, NSWindowDelegate {
    private weak var viewModel: OutlinerViewModel?
    private weak var window: NSWindow?
    private var previousDelegate: NSWindowDelegate?
    private var bypassNextClosePrompt = false

    init(viewModel: OutlinerViewModel) {
        self.viewModel = viewModel
    }

    func update(viewModel: OutlinerViewModel) {
        self.viewModel = viewModel
    }

    func attach(to window: NSWindow) {
        if self.window !== window {
            self.window = window
            if let existing = window.delegate, existing !== self {
                previousDelegate = existing
            }
        }

        if window.delegate !== self {
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let shouldClose = previousDelegate?.windowShouldClose?(sender), !shouldClose {
            return false
        }

        if bypassNextClosePrompt {
            bypassNextClosePrompt = false
            return true
        }

        guard let viewModel else { return true }
        let intercepted = viewModel.interceptWindowCloseIfNeeded { [weak self, weak sender] in
            guard let self, let sender else { return }
            self.bypassNextClosePrompt = true
            sender.performClose(nil)
        }
        return !intercepted
    }
}

struct WindowCloseBridge: NSViewRepresentable {
    var viewModel: OutlinerViewModel

    final class Coordinator {
        private let closeCoordinator: WindowCloseCoordinator

        init(viewModel: OutlinerViewModel) {
            closeCoordinator = WindowCloseCoordinator(viewModel: viewModel)
        }

        func update(viewModel: OutlinerViewModel) {
            closeCoordinator.update(viewModel: viewModel)
        }

        func attach(to window: NSWindow) {
            closeCoordinator.attach(to: window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(viewModel: viewModel)
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            context.coordinator.attach(to: window)
        }
    }
}
