import AppKit
import XCTest

final class ProvenanceCleanerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var temporaryDirectory: URL!
    private var helperURL: URL!
    private var processLogURL: URL!
    private var requestLogURL: URL!
    private var blockMarkerURL: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceCleanerUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        helperURL = temporaryDirectory.appendingPathComponent("ui-test-helper.py")
        processLogURL = temporaryDirectory.appendingPathComponent("processes.log")
        requestLogURL = temporaryDirectory.appendingPathComponent("requests.log")
        blockMarkerURL = temporaryDirectory.appendingPathComponent("blocked-clean.marker")
        try writeHelper()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testEmptyStateLaunchesInLightAndDarkAppearances() throws {
        launch(appearance: "light")
        assertEmptyState(appearance: "light")
        app.terminate()

        launch(appearance: "dark")
        assertEmptyState(appearance: "dark")
    }

    func testRealMetadataEditorAndCertificateViewsInBothAppearances() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("HelperIntegration/Fixtures")
        for appearance in ["light", "dark"] {
            launch(importing: [fixtures.appendingPathComponent("editing-traces.docx"), fixtures.appendingPathComponent("signed-c2pa.jpg")], appearance: appearance, realEngine: true)
            let metadataTab = element(identifier: "detail.tab.metadata")
            XCTAssertTrue(metadataTab.waitForExistence(timeout: 10))
            metadataTab.click()
            let author = app.textFields["metadata.author"]
            XCTAssertTrue(author.waitForExistence(timeout: 20))
            XCTAssertTrue(waitUntil(timeout: 30) { author.isEnabled })
            let title = app.textFields["metadata.title"]
            XCTAssertEqual(author.frame.minX, title.frame.minX, accuracy: 1)
            XCTAssertEqual(author.frame.width, title.frame.width, accuracy: 1)
            author.click()
            app.typeKey("a", modifierFlags: .command)
            author.typeText("Interface Review")
            let apply = element(identifier: "metadata.apply")
            XCTAssertTrue(apply.isEnabled)
            apply.click()
            let review = app.buttons["Review Before Export"]
            XCTAssertTrue(review.waitForExistence(timeout: 30))
            review.click()
            element(identifier: "detail.tab.metadata").click()
            XCTAssertEqual(app.textFields["metadata.author"].value as? String, "Interface Review")
            let metadataShot = XCTAttachment(screenshot: app.screenshot())
            metadataShot.name = "metadata-\(appearance)"
            metadataShot.lifetime = .keepAlways
            add(metadataShot)
            element(identifier: "queue.row.signed-c2pa.jpg").click()
            element(identifier: "detail.tab.overview").click()
            XCTAssertTrue(element(identifier: "credentials.card").waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Not trusted", "Not trusted")).firstMatch.exists)
            let credentialsShot = XCTAttachment(screenshot: app.screenshot())
            credentialsShot.name = "credentials-\(appearance)"
            credentialsShot.lifetime = .keepAlways
            add(credentialsShot)
            app.terminate()
        }
    }

    func testCommandOOpensAddFilesPanel() throws {
        launch()

        app.typeKey("o", modifierFlags: .command)
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Command-O should open the file panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !cancelButton.exists })
    }

    func testFinderDragAndDropImportsAndInspectsFile() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("Window tiling used by this native Finder gesture is available on macOS 15+")
        }

        let fixture = try writeFixture(named: "finder-drop.txt", contents: "owned\u{200B}content")
        launch()

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([fixture])
        finder.activate()

        let finderItem = finder.textFields[fixture.lastPathComponent].firstMatch
        XCTAssertTrue(
            finderItem.waitForExistence(timeout: 8),
            "Finder should reveal the drag fixture"
        )

        tileCurrentWindow(of: finder, side: "Left")
        tileCurrentWindow(of: app, side: "Right")
        finder.activate()

        let source = finderItem.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let destination = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)
        )
        source.press(forDuration: 0.8, thenDragTo: destination)

        assertStatus("1 finding", for: fixture.lastPathComponent)
    }

    func testFixtureImportShowsMixedQueueStatusesAndKeyboardCommands() throws {
        let plain = try writeFixture(named: "plain.txt", contents: "ordinary text")
        let marked = try writeFixture(named: "marked.txt", contents: "owned\u{200B}content")
        let unsupported = try writeFixture(named: "unsupported.bin", contents: "bytes")
        let missing = temporaryDirectory.appendingPathComponent("missing.txt")
        launch(importing: [plain, marked, unsupported, missing])

        assertStatus("No actionable findings", for: plain.lastPathComponent)
        assertStatus("1 finding", for: marked.lastPathComponent)
        assertStatus("Unsupported", for: unsupported.lastPathComponent)
        assertStatus("Failed", for: missing.lastPathComponent)
        assertText("Text", identifier: "queue.type.\(plain.lastPathComponent)")
        assertText("Text", identifier: "queue.type.\(marked.lastPathComponent)")
        assertText("Unknown", identifier: "queue.type.\(unsupported.lastPathComponent)")

        let markedRow = element(identifier: "queue.row.\(marked.lastPathComponent)")
        XCTAssertTrue(markedRow.waitForExistence(timeout: 5))
        markedRow.click()
        openQuickLookFromMenu()
        XCTAssertTrue(element(identifier: "preview.pane.original").waitForExistence(timeout: 5))

        let requestCountBeforeInspectAll = requestOperations().filter { $0 == "inspect" }.count
        app.typeKey("i", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil(timeout: 10) {
            self.requestOperations().filter { $0 == "inspect" }.count
                >= requestCountBeforeInspectAll + 2
        })

        let unsupportedRow = element(identifier: "queue.row.\(unsupported.lastPathComponent)")
        unsupportedRow.click()
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !unsupportedRow.exists })
    }

    func testCleanKeyboardCommandPresentsReviewAndExportPrompt() throws {
        let marked = try writeFixture(named: "review.txt", contents: "owned\u{200B}content")
        launch(importing: [marked])
        assertStatus("1 finding", for: marked.lastPathComponent)

        app.typeKey(.return, modifierFlags: .command)

        let reviewButton = app.sheets.buttons["Review Before Export"].firstMatch
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.buttons["Save Cleaned Copy…"].firstMatch.exists)
        XCTAssertTrue(app.sheets.buttons["Replace Original and Keep .bak"].firstMatch.exists)
        reviewButton.click()

        assertStatus("Cleaned — findings removed", for: marked.lastPathComponent)
        openQuickLookFromMenu()
        XCTAssertTrue(element(identifier: "preview.pane.original").waitForExistence(timeout: 5))
        XCTAssertTrue(element(identifier: "preview.pane.cleaned").waitForExistence(timeout: 5))

        app.typeKey("e", modifierFlags: .command)
        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Command-E should open the export save panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5) { !cancelButton.exists })
    }

    func testMissingCapabilitiesAppearsInSettingsDiagnostics() throws {
        launch(helperMode: "missing-capabilities")

        app.menuBars.menuBarItems["Provenance Cleaner"].click()
        app.menuItems["Settings…"].click()
        let privacyButton = app.buttons["Privacy"]
        XCTAssertTrue(privacyButton.waitForExistence(timeout: 5), "The app menu should open Settings")
        privacyButton.click()

        let unavailable = element(identifier: "settings.engine-unavailable")
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        let error = element(identifier: "settings.engine-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(accessibilityText(of: error).contains("UI test capabilities unavailable"))
    }

    func testCancellationTerminatesHelperAndNextRequestRestartsIt() throws {
        let marked = try writeFixture(named: "cancel.txt", contents: "owned\u{200B}content")
        launch(importing: [marked], helperMode: "block-first-clean")
        assertStatus("1 finding", for: marked.lastPathComponent)

        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 10) {
            FileManager.default.fileExists(atPath: self.blockMarkerURL.path)
        })

        let stopButton = element(identifier: "toolbar.stop")
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        app.activate()
        stopButton.click()
        assertStatus("Cancelled", for: marked.lastPathComponent)

        app.typeKey("i", modifierFlags: [.command, .shift])
        assertStatus("1 finding", for: marked.lastPathComponent)

        XCTAssertTrue(waitUntil(timeout: 5) { self.uniqueHelperProcessCount() >= 2 })
    }

    private func launch(
        importing urls: [URL] = [],
        appearance: String? = nil,
        helperMode: String = "normal",
        realEngine: Bool = false
    ) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment = [
            "PROVENANCE_CLEANER_UI_TESTING": "1",
            "PROVENANCE_CLEANER_UI_TEST_ACCEPT_OWNERSHIP": "1",
            "PROVENANCE_CLEANER_HELPER_PATH": helperURL.path,
            "PC_UI_TEST_HELPER_MODE": helperMode,
            "PC_UI_TEST_PROCESS_LOG": processLogURL.path,
            "PC_UI_TEST_REQUEST_LOG": requestLogURL.path,
            "PC_UI_TEST_BLOCK_MARKER": blockMarkerURL.path,
        ]
        if let appearance {
            app.launchEnvironment["PROVENANCE_CLEANER_UI_TEST_APPEARANCE"] = appearance
        }
        if !urls.isEmpty {
            app.launchEnvironment["PROVENANCE_CLEANER_UI_TEST_IMPORT_PATHS"] = urls
                .map(\.path)
                .joined(separator: "\n")
        }
        if realEngine { app.launchEnvironment.removeValue(forKey: "PROVENANCE_CLEANER_HELPER_PATH") }
        app.launch()
        app.activate()
        if !app.windows.firstMatch.waitForExistence(timeout: 1) {
            app.typeKey("n", modifierFlags: [.command, .shift])
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 8))
        app.activate()
    }

    private func assertEmptyState(appearance: String) {
        XCTAssertTrue(app.staticTexts["Drop files to begin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No files"].exists)
        XCTAssertTrue(element(identifier: "empty-state.add-files").exists)

        let probe = element(identifier: "ui-test.appearance")
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertEqual(probe.value as? String, appearance)
    }

    private func assertStatus(
        _ expectedStatus: String,
        for filename: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let status = element(identifier: "queue.status.\(filename)")
        XCTAssertTrue(status.waitForExistence(timeout: 12), file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 12) { self.accessibilityText(of: status) == expectedStatus },
            "Expected \(filename) to reach status '\(expectedStatus)'; current text is '\(accessibilityText(of: status))'",
            file: file,
            line: line
        )
    }

    private func accessibilityText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    private func assertText(
        _ expectedText: String,
        identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = element(identifier: identifier)
        XCTAssertTrue(value.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(accessibilityText(of: value), expectedText, file: file, line: line)
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openQuickLookFromMenu() {
        app.menuBars.menuBarItems["Process"].click()
        app.menuItems["Quick Look"].click()
    }

    @available(macOS 15.0, *)
    private func tileCurrentWindow(of application: XCUIApplication, side: String) {
        application.activate()
        application.menuBars.menuBarItems["Window"].click()
        let item = application.menuItems[side].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window menu should expose the \(side) tile action")
        item.click()
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline
        return condition()
    }

    private func writeFixture(named name: String, contents: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func requestOperations() -> [String] {
        guard let data = try? Data(contentsOf: requestLogURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    private func uniqueHelperProcessCount() -> Int {
        guard let data = try? Data(contentsOf: processLogURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return 0
        }
        return Set(text.split(separator: "\n")).count
    }

    private func writeHelper() throws {
        let script = #"""
        #!/usr/bin/python3
        import json
        import os
        import shutil
        import sys
        import time

        MODE = os.environ.get("PC_UI_TEST_HELPER_MODE", "normal")
        PROCESS_LOG = os.environ["PC_UI_TEST_PROCESS_LOG"]
        REQUEST_LOG = os.environ["PC_UI_TEST_REQUEST_LOG"]
        BLOCK_MARKER = os.environ["PC_UI_TEST_BLOCK_MARKER"]

        with open(PROCESS_LOG, "a", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}\n")

        def respond(request_id, ok, kind="unknown", report=None, output_path=None, error=None):
            payload = {
                "requestID": request_id,
                "ok": ok,
                "kind": kind,
                "report": report or {},
            }
            if output_path is not None:
                payload["outputPath"] = output_path
            if error is not None:
                payload["error"] = error
            print(json.dumps(payload, separators=(",", ":")), flush=True)

        for line in sys.stdin:
            request = json.loads(line)
            operation = request["operation"]
            request_id = request["requestID"]
            with open(REQUEST_LOG, "a", encoding="utf-8") as handle:
                handle.write(operation + "\n")

            if operation == "capabilities":
                if MODE == "missing-capabilities":
                    respond(request_id, False, error="UI test capabilities unavailable")
                else:
                    respond(request_id, True, kind="capabilities", report={"ui_test": True})
                continue

            input_path = request["inputPath"]
            with open(input_path, "r", encoding="utf-8") as handle:
                text = handle.read()
            findings = ["Zero-width space U+200B"] if "\u200b" in text else []

            if operation == "inspect":
                respond(
                    request_id,
                    True,
                    kind="text",
                    report={
                        "findings": findings,
                        "findings_confidence": ["confirmed"] * len(findings),
                        "suspicious_total": len(findings),
                    },
                )
                continue

            if operation == "clean":
                if MODE == "block-first-clean" and not os.path.exists(BLOCK_MARKER):
                    with open(BLOCK_MARKER, "w", encoding="utf-8") as handle:
                        handle.write("blocked")
                    while True:
                        time.sleep(1)

                output_path = request["outputPath"]
                with open(output_path, "w", encoding="utf-8") as handle:
                    handle.write(text.replace("\u200b", ""))
                respond(
                    request_id,
                    True,
                    kind="text",
                    report={
                        "actions": ["Removed invisible Unicode"],
                        "changed": text != text.replace("\u200b", ""),
                        "post_findings": [],
                    },
                    output_path=output_path,
                )
                continue

            respond(request_id, False, error="Unsupported UI test operation")
        """#
        try Data(script.utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )
    }
}
