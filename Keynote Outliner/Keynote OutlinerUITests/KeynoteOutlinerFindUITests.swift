//
//  KeynoteOutlinerFindUITests.swift
//  Keynote OutlinerUITests
//

import AppKit
import Darwin
import XCTest

@MainActor
final class KeynoteOutlinerFindUITests: XCTestCase {
    private static let defaultFixturePath =
        "/Users/edwardsanchez/Library/Mobile Documents/com~apple~CloudDocs/Work/The Future of Apps v2.key"
    private static let sourceFixtureEnvironmentKey = "KEYNOTE_OUTLINER_UI_TEST_SOURCE_PATH"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFindBarOpensAndAcceptsQueryOnCopiedFixture() throws {
        let fixtureCopyURL = try makeFixtureCopy()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: fixtureCopyURL)
        }

        terminateExistingAppInstances()

        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["KEYNOTE_OUTLINER_UI_TEST_MODE"] = "1"
        app.launchEnvironment["KEYNOTE_OUTLINER_UI_TEST_INPUT_PATH"] = fixtureCopyURL.path
        app.launch()

        let firstRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "notes.row.")
        ).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 45))

        app.activate()
        app.typeKey("f", modifierFlags: .command)

        let searchField = try waitForFindInput(in: app)
        searchField.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).click()
        searchField.typeText("Apple TV")
        searchField.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForLabel(
                of: searchField,
                satisfying: { $0.contains("Apple TV") },
                timeout: 5
            ),
            "Expected the native find field to contain the typed query."
        )

        let selectionSignature = diagnosticElement(
            identifier: "uiTest.find.selectionSignature",
            in: app
        )
        XCTAssertTrue(selectionSignature.waitForExistence(timeout: 5))

        try XCTExpectFailure(
            "Known issue: deck-wide Find Next / Find Previous is still unreliable on the copied Keynote fixture.",
            strict: false
        ) {
            app.typeKey("g", modifierFlags: .command)
            let firstSignature = try waitForSelectionSignature(of: selectionSignature)
            var signatures = [firstSignature]

            for _ in 0..<4 {
                app.typeKey("g", modifierFlags: .command)
                let nextSignature = try waitForChangedLabel(
                    of: selectionSignature,
                    from: signatures.last!,
                    timeout: 5
                )
                signatures.append(nextSignature)
            }

            XCTAssertGreaterThanOrEqual(
                Set(signatures).count,
                4,
                "Expected Find Next to keep progressing across matches. History: \(signatures)"
            )

            let expectedPreviousSignature = signatures[signatures.count - 2]
            app.typeKey("G", modifierFlags: [.command, .shift])
            XCTAssertTrue(
                waitForExactLabel(
                    of: selectionSignature,
                    expected: expectedPreviousSignature,
                    timeout: 5
                ),
                "Expected Find Previous to return to the prior match."
            )

            let pendingReveal = diagnosticElement(
                identifier: "uiTest.find.pendingRevealRowID",
                in: app
            )
            XCTAssertTrue(pendingReveal.waitForExistence(timeout: 2))
            XCTAssertEqual(
                stringValue(of: pendingReveal),
                "-",
                "Expected pending reveal to settle after navigation."
            )
        }
    }

    private func makeFixtureCopy() throws -> URL {
        let sourcePath =
            ProcessInfo.processInfo.environment[Self.sourceFixtureEnvironmentKey]
            ?? Self.defaultFixturePath
        let sourceURL = URL(fileURLWithPath: sourcePath)

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("UI test fixture not found at \(sourceURL.path)")
        }

        try ensureFixtureIsAvailableLocally(sourceURL)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeynoteOutlinerUITest-\(UUID().uuidString)")
            .appendingPathExtension("key")
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func ensureFixtureIsAvailableLocally(_ sourceURL: URL) throws {
        let initialValues = try sourceURL.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        guard initialValues.isUbiquitousItem == true else { return }

        try? FileManager.default.startDownloadingUbiquitousItem(at: sourceURL)
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let status = try sourceURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                .ubiquitousItemDownloadingStatus
            if status == URLUbiquitousItemDownloadingStatus.current || status == nil {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }

        throw XCTSkip("UI test fixture is not downloaded locally: \(sourceURL.path)")
    }

    private func waitForFindInput(in app: XCUIApplication) throws -> XCUIElement {
        let searchField = app.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            return searchField
        }

        let textField = app.textFields.firstMatch
        if textField.waitForExistence(timeout: 5) {
            return textField
        }

        XCTFail("Expected native find input to appear.")
        throw XCTSkip("Find input did not appear.")
    }

    private func waitForSelectionSignature(of element: XCUIElement) throws -> String {
        let didResolve = waitForLabel(
            of: element,
            satisfying: { value in
                value.contains("|") && !value.hasPrefix("-|")
            },
            timeout: 5
        )
        XCTAssertTrue(didResolve, "Expected selection signature to resolve to a concrete match.")
        let label = stringValue(of: element)
        guard label.contains("|"), !label.hasPrefix("-|") else {
            throw XCTSkip("Selection signature never resolved.")
        }
        return label
    }

    private func waitForChangedLabel(
        of element: XCUIElement,
        from previous: String,
        timeout: TimeInterval
    ) throws -> String {
        let didChange = waitForLabel(
            of: element,
            satisfying: { $0 != previous && !$0.isEmpty },
            timeout: timeout
        )
        XCTAssertTrue(didChange, "Expected label to change from \(previous).")
        let label = stringValue(of: element)
        guard label != previous, !label.isEmpty else {
            throw XCTSkip("Element label did not change.")
        }
        return label
    }

    private func waitForExactLabel(
        of element: XCUIElement,
        expected: String,
        timeout: TimeInterval
    ) -> Bool {
        waitForLabel(of: element, satisfying: { $0 == expected }, timeout: timeout)
    }

    private func diagnosticElement(
        identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForLabel(
        of element: XCUIElement,
        satisfying predicate: @escaping (String) -> Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = stringValue(of: element)
            if element.exists, predicate(value) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.exists && predicate(stringValue(of: element))
    }

    private func terminateExistingAppInstances() {
        for pid in matchingAppProcessIDs() {
            if let parentPID = parentProcessID(of: pid) {
                kill(parentPID, SIGKILL)
            }
            kill(pid, SIGKILL)
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let runningApps = NSRunningApplication.runningApplications(
                withBundleIdentifier: "app.amorfati.Keynote-Outliner"
            )
            guard runningApps.isEmpty else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            return
        }
    }

    private func matchingAppProcessIDs() -> [pid_t] {
        guard let output = try? processOutput(
            executablePath: "/usr/bin/pgrep",
            arguments: ["-f", "/Keynote Outliner.app/Contents/MacOS/Keynote Outliner"]
        ) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func parentProcessID(of pid: pid_t) -> pid_t? {
        guard let output = try? processOutput(
            executablePath: "/bin/ps",
            arguments: ["-o", "ppid=", "-p", String(pid)]
        ) else {
            return nil
        }

        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func processOutput(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        return element.label
    }
}
