//
//  KeynoteBackendClient.swift
//  Keynote Outliner
//

import Foundation

enum BackendClientError: LocalizedError {
    case missingPythonExecutable(String)
    case missingBackendScript(String)
    case failedToLaunch(String)
    case processFailure(String)
    case invalidResponse(String)
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case .missingPythonExecutable(let path):
            return "Python executable not found at \(path)."
        case .missingBackendScript(let path):
            return "Backend script not found at \(path)."
        case .failedToLaunch(let message):
            return "Failed to launch backend process: \(message)"
        case .processFailure(let message):
            return "Backend process failed: \(message)"
        case .invalidResponse(let message):
            return "Backend returned invalid JSON: \(message)"
        case .backendError(let message):
            return message
        }
    }
}

actor KeynoteBackendClient {
    private enum DefaultsKeys {
        static let pythonPath = "KeynoteOutlinerPythonPath"
        static let scriptPath = "KeynoteOutlinerBackendScriptPath"
    }

    private struct LoadSlidePayload: Decodable {
        var index: Int
        var slideNodeId: String
        var slideId: String
        var noteArchiveId: String?
        var noteStorageId: String?
        var noteText: String
        var thumbnailPath: String?
    }

    private struct LoadResponsePayload: Decodable {
        var file: DeckFileFingerprint?
        var slides: [LoadSlidePayload]?
        var status: String?
        var error: String?
    }

    private static let sourcePath = URL(fileURLWithPath: #filePath)

    func load(input: URL, cacheDir: URL) async throws -> DeckSnapshot {
        let output = try runBackend(
            arguments: [
                "load",
                "--input", input.path,
                "--cache-dir", cacheDir.path,
            ]
        )
        let decoder = JSONDecoder()
        let payload: LoadResponsePayload
        do {
            payload = try decoder.decode(LoadResponsePayload.self, from: output)
        } catch {
            throw BackendClientError.invalidResponse(error.localizedDescription)
        }

        if payload.status == BackendSaveStatus.error.rawValue {
            throw BackendClientError.backendError(payload.error ?? "Unknown backend load error.")
        }

        guard let file = payload.file, let slides = payload.slides else {
            throw BackendClientError.invalidResponse("Missing file or slides in load response.")
        }

        return DeckSnapshot(
            file: file,
            slides: slides.map {
                SlideRowModel(
                    index: $0.index,
                    slideNodeId: $0.slideNodeId,
                    slideId: $0.slideId,
                    noteArchiveId: $0.noteArchiveId,
                    noteStorageId: $0.noteStorageId,
                    baseNoteText: $0.noteText,
                    editedNoteText: $0.noteText,
                    thumbnailPath: $0.thumbnailPath
                )
            }
        )
    }

    func save(
        input: URL,
        output: URL,
        state: SaveStatePayload,
        mode: SaveMode,
        cacheDir: URL
    ) async throws -> SaveResponse {
        let stateFile = cacheDir.appendingPathComponent("save-state-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try await MainActor.run { try encoder.encode(state) }
        try FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: stateFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stateFile) }

        let outputData = try runBackend(
            arguments: [
                "save",
                "--input", input.path,
                "--output", output.path,
                "--state-json", stateFile.path,
                "--mode", mode.rawValue,
            ]
        )

        let decoder = JSONDecoder()
        let response: SaveResponse
        do {
            response = try await MainActor.run {
                try decoder.decode(SaveResponse.self, from: outputData)
            }
        } catch {
            throw BackendClientError.invalidResponse(error.localizedDescription)
        }
        if response.status == .error {
            throw BackendClientError.backendError(response.error ?? response.message ?? "Unknown backend save error.")
        }
        return response
    }

    private func runBackend(arguments: [String]) throws -> Data {
        let pythonURL = try resolvePythonExecutableURL()
        let scriptURL = try resolveBackendScriptURL()

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONWARNINGS"] = "ignore:KeynoteVersionWarning"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BackendClientError.failedToLaunch(error.localizedDescription)
        }
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderrText = String(decoding: stderr, as: UTF8.self)
            let stdoutText = String(decoding: stdout, as: UTF8.self)
            throw BackendClientError.processFailure(
                [stderrText, stdoutText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }
        return stdout
    }

    private func resolvePythonExecutableURL() throws -> URL {
        if let overridePath = UserDefaults.standard.string(forKey: DefaultsKeys.pythonPath) {
            let url = URL(fileURLWithPath: overridePath)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            throw BackendClientError.missingPythonExecutable(overridePath)
        }

        guard let repoRoot = findRepoRoot() else {
            throw BackendClientError.missingPythonExecutable("Could not infer repo root from source path.")
        }
        let defaultPython = repoRoot.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: defaultPython.path) {
            return defaultPython
        }
        throw BackendClientError.missingPythonExecutable(defaultPython.path)
    }

    private func resolveBackendScriptURL() throws -> URL {
        if let overridePath = UserDefaults.standard.string(forKey: DefaultsKeys.scriptPath) {
            let url = URL(fileURLWithPath: overridePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            throw BackendClientError.missingBackendScript(overridePath)
        }

        guard let repoRoot = findRepoRoot() else {
            throw BackendClientError.missingBackendScript("Could not infer repo root from source path.")
        }
        let scriptURL = repoRoot.appendingPathComponent("scripts/keynote_outliner_backend.py")
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            return scriptURL
        }
        throw BackendClientError.missingBackendScript(scriptURL.path)
    }

    private func findRepoRoot() -> URL? {
        var cursor = Self.sourcePath.deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = cursor.appendingPathComponent("scripts/keynote_outliner_backend.py")
            if FileManager.default.fileExists(atPath: marker.path) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                break
            }
            cursor = parent
        }
        return nil
    }
}
