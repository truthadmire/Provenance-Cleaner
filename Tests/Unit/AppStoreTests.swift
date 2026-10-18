import Foundation
import XCTest
@testable import ProvenanceCleaner

final class AppStoreTests: XCTestCase {
    @MainActor
    func testPropertyEditsRunAfterCleaningInOneCopyFromTheOriginal() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.docx", contents: "original")
        let engine = RecordingEngine()
        let stage = fixture.root.appendingPathComponent("stage")
        let store = AppStore(engine: engine, preferences: try makePreferences(), stagingRoot: stage)
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)
        store.updatePlan(for: id) { $0.propertyEdits = ["author": "Alice", "title": ""] }

        await store.createCopy(jobID: id)

        let names = await engine.cleanedSourceNames()
        let options = await engine.receivedOptions()
        XCTAssertEqual(names, ["input.docx", "cleaned.docx"])
        XCTAssertEqual(options.count, 2)
        XCTAssertNil(options[0].metadataEdits)
        XCTAssertEqual(options[1].metadataEdits, ["author": "Alice", "title": ""])
        XCTAssertEqual(store.selectedJob?.status, .readyToExport(residualCount: 0))
        XCTAssertEqual(store.selectedJob?.buildSteps.map(\.kind), [.provenance, .properties])
        XCTAssertEqual(store.selectedJob?.appliedPlan, store.selectedJob?.plan)
        XCTAssertTrue(store.selectedJob?.canExport == true)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "original")
        // Only the final step's staging directory survives.
        let jobStage = stage.appendingPathComponent(id.uuidString)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: jobStage.path).count, 1)

        await store.inspect(jobID: id)
        let inspectedNames = await engine.allInspectedSourceNames()
        XCTAssertEqual(inspectedNames.last, store.selectedJob?.stagedOutputURL?.lastPathComponent)
        XCTAssertEqual(store.selectedJob?.status, .readyToExport(residualCount: 0))
    }

    @MainActor
    func testRebuildAlwaysStartsFromTheOriginal() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.docx", contents: "original")
        let engine = RecordingEngine()
        let store = AppStore(engine: engine, preferences: try makePreferences(), stagingRoot: fixture.root.appendingPathComponent("stage"))
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)
        await store.createCopy(jobID: id)
        store.updatePlan(for: id) { $0.propertyEdits = ["author": "Alice"] }

        await store.createCopy(jobID: id)

        let names = await engine.cleanedSourceNames()
        XCTAssertEqual(names, ["input.docx", "input.docx", "cleaned.docx"])
    }

    @MainActor
    func testFailedStepKeepsPreviousCopyAndAllowsRetry() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.docx", contents: "original")
        let engine = RecordingEngine(cleanOutcomes: [.success("copy"), .success("second"), .failure("unsupported field")])
        let store = AppStore(engine: engine, preferences: try makePreferences(), stagingRoot: fixture.root.appendingPathComponent("stage"))
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)
        await store.createCopy(jobID: id)
        let previous = try XCTUnwrap(store.selectedJob?.stagedOutputURL)
        store.updatePlan(for: id) { $0.propertyEdits = ["author": "Alice"] }

        await store.createCopy(jobID: id)

        XCTAssertEqual(store.selectedJob?.stagedOutputURL, previous)
        XCTAssertEqual(store.selectedJob?.status, .failed("Update document properties failed: unsupported field"))
        XCTAssertTrue(store.selectedJob?.status.canClean == true)
        XCTAssertTrue(store.selectedJob?.canExport == true)
        XCTAssertEqual(try String(contentsOf: previous, encoding: .utf8), "copy")
    }

    @MainActor
    func testWordTracesRunAfterCleaningWithTheirOwnOptions() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.docx", contents: "test document")
        let engine = RecordingEngine()
        let preferences = try makePreferences()
        preferences.wordSessionMode = .remove
        let store = AppStore(engine: engine, preferences: preferences, stagingRoot: fixture.root.appendingPathComponent("stage"))
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)
        store.updatePlan(for: id) { $0.changeWordTraces = true }

        await store.createCopy(jobID: id)

        let options = await engine.receivedOptions()
        XCTAssertEqual(options.count, 2)
        XCTAssertNil(options[0].wordTraces)
        XCTAssertEqual(options[1].wordTraces?.rsids, .remove)
        XCTAssertEqual(store.selectedJob?.status, .readyToExport(residualCount: 0))
        XCTAssertTrue(store.selectedJob?.canExport == true)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "test document")
    }

    @MainActor
    func testWordTracesAreIgnoredForOtherFormats() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("notes.txt", contents: "text\u{200B}")
        let engine = RecordingEngine()
        let store = AppStore(engine: engine, preferences: try makePreferences(), stagingRoot: fixture.root.appendingPathComponent("stage"))
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)
        store.updatePlan(for: id) { $0.changeWordTraces = true }

        await store.createCopy(jobID: id)

        let options = await engine.receivedOptions()
        XCTAssertEqual(options, [.conservative])
    }

    @MainActor
    func testEmptyOrInvalidPlanCannotCreateCopy() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.docx", contents: "original")
        let engine = RecordingEngine()
        let store = AppStore(engine: engine, preferences: try makePreferences(), stagingRoot: fixture.root.appendingPathComponent("stage"))
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)

        store.updatePlan(for: id) { $0.removeProvenance = false }
        XCTAssertFalse(store.canCreateCopy(try XCTUnwrap(store.selectedJob)))
        store.updatePlan(for: id) { $0.propertyEdits = ["author": "bad\u{0007}value"] }
        XCTAssertFalse(store.canCreateCopy(try XCTUnwrap(store.selectedJob)))

        await store.createCopy(jobID: id)

        let names = await engine.cleanedSourceNames()
        XCTAssertTrue(names.isEmpty)
        XCTAssertNil(store.selectedJob?.stagedOutputURL)
    }

    @MainActor
    func testCopyNeedsUpdateAfterPlanOrSettingsChange() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.docx", contents: "original")
        let preferences = try makePreferences()
        let store = AppStore(engine: RecordingEngine(), preferences: preferences, stagingRoot: fixture.root.appendingPathComponent("stage"))
        await store.addAndInspect([source])
        let id = try XCTUnwrap(store.selectedJobID)
        await store.createCopy(jobID: id)
        XCTAssertFalse(store.copyNeedsUpdate(try XCTUnwrap(store.selectedJob)))

        store.updatePlan(for: id) { $0.propertyEdits = ["title": "Report"] }
        XCTAssertTrue(store.copyNeedsUpdate(try XCTUnwrap(store.selectedJob)))
        store.updatePlan(for: id) { $0.propertyEdits = [:] }
        XCTAssertFalse(store.copyNeedsUpdate(try XCTUnwrap(store.selectedJob)))

        preferences.normalizeSpaces = true
        XCTAssertTrue(store.copyNeedsUpdate(try XCTUnwrap(store.selectedJob)))
    }

    @MainActor
    func testFailedPDFDeepPassKeepsOutputButShowsIncompleteStatus() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let source = try fixture.write("input.pdf", contents: "test input")
        let store = AppStore(
            engine: RecordingEngine(pdfDeepCleaningIncomplete: true),
            preferences: try makePreferences(),
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )
        await store.addAndInspect([source])
        await store.createCopyForSelected()
        XCTAssertEqual(store.selectedJob?.status, .cleanedInspectionIncomplete)
        XCTAssertTrue(store.selectedJob?.canExport == true)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "test input")
    }

    @MainActor
    func testAddAutomaticallyInspectsAndSelectsFirstItem() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let firstURL = try fixture.write("first.txt", contents: "hello")
        let secondURL = try fixture.write("second.txt", contents: "world")
        let engine = RecordingEngine()
        let store = AppStore(
            engine: engine,
            preferences: try makePreferences(),
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )

        await store.addAndInspect([firstURL, secondURL])

        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertEqual(store.selectedJobID, store.jobs.first?.id)
        XCTAssertEqual(store.jobs.map(\.kind), [.text, .text])
        XCTAssertTrue(store.jobs.allSatisfy {
            if case .findings = $0.status { return true }
            return false
        })
        let inspectedNames = await engine.inspectedSourceNames()
        XCTAssertEqual(inspectedNames, ["first.txt", "second.txt"])
    }

    @MainActor
    func testCleanAllRunsSequentiallyWithConservativeOptions() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let firstURL = try fixture.write("one.txt", contents: "one\u{200B}")
        let secondURL = try fixture.write("two.txt", contents: "two\u{200B}")
        let engine = RecordingEngine(cleanDelayNanoseconds: 20_000_000)
        let preferences = try makePreferences()
        let store = AppStore(
            engine: engine,
            preferences: preferences,
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )
        await store.addAndInspect([firstURL, secondURL])

        await store.createAllCopies()

        let maximumConcurrentCleans = await engine.maximumConcurrentCleans()
        let cleanedNames = await engine.cleanedSourceNames()
        XCTAssertEqual(maximumConcurrentCleans, 1)
        XCTAssertEqual(cleanedNames, ["one.txt", "two.txt"])
        let options = await engine.receivedOptions()
        XCTAssertEqual(options, [.conservative, .conservative])
        XCTAssertTrue(store.jobs.allSatisfy(\.canExport))
        XCTAssertTrue(store.jobs.allSatisfy {
            if case let .readyToExport(residualCount) = $0.status { return residualCount == 0 }
            return false
        })
    }

    @MainActor
    func testCleanAllContinuesAfterOneFileFailsAndPreservesPerFileResults() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let firstURL = try fixture.write("fails.txt", contents: "first\u{200B}")
        let secondURL = try fixture.write("succeeds.txt", contents: "second\u{200B}")
        let engine = RecordingEngine(cleanOutcomes: [
            .failure("planned batch failure"),
            .success("second-clean"),
        ])
        let store = AppStore(
            engine: engine,
            preferences: try makePreferences(),
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )
        await store.addAndInspect([firstURL, secondURL])

        await store.createAllCopies()

        let cleanedNames = await engine.cleanedSourceNames()
        XCTAssertEqual(cleanedNames, ["fails.txt", "succeeds.txt"])
        guard case let .failed(message) = store.jobs[0].status else {
            return XCTFail("Expected the first job to retain its individual failure")
        }
        XCTAssertEqual(message, "planned batch failure")
        XCTAssertNil(store.jobs[0].stagedOutputURL)
        guard case let .readyToExport(residualCount) = store.jobs[1].status else {
            return XCTFail("Expected the second job to finish despite the first failure")
        }
        XCTAssertEqual(residualCount, 0)
        XCTAssertEqual(
            try String(contentsOf: XCTUnwrap(store.jobs[1].stagedOutputURL), encoding: .utf8),
            "second-clean"
        )
    }

    @MainActor
    func testUnknownExtensionIsRefusedWithoutCallingEngine() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let unknownURL = try fixture.write("payload.bin", contents: "not text by extension")
        let engine = RecordingEngine()
        let store = AppStore(
            engine: engine,
            preferences: try makePreferences(),
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )

        await store.addAndInspect([unknownURL])

        XCTAssertEqual(store.jobs.count, 1)
        guard case .unsupported = store.jobs[0].status else {
            return XCTFail("Expected unsupported status")
        }
        let inspectedNames = await engine.inspectedSourceNames()
        XCTAssertTrue(inspectedNames.isEmpty)
    }

    @MainActor
    func testFailedRecleanPreservesPreviousStagedResult() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("draft.txt", contents: "draft\u{200B}")
        let engine = RecordingEngine(cleanOutcomes: [
            .success("first-clean"),
            .failure("planned failure"),
        ])
        let store = AppStore(
            engine: engine,
            preferences: try makePreferences(),
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )
        await store.addAndInspect([sourceURL])
        let jobID = try XCTUnwrap(store.jobs.first?.id)
        await store.createCopy(jobID: jobID)
        let previousOutputURL = try XCTUnwrap(store.jobs.first?.stagedOutputURL)
        XCTAssertEqual(try String(contentsOf: previousOutputURL, encoding: .utf8), "first-clean")

        await store.createCopy(jobID: jobID)

        XCTAssertEqual(store.jobs.first?.stagedOutputURL, previousOutputURL)
        XCTAssertEqual(try String(contentsOf: previousOutputURL, encoding: .utf8), "first-clean")
        guard case let .failed(message) = store.jobs.first?.status else {
            return XCTFail("Expected the failed re-clean to retain a failed status")
        }
        XCTAssertEqual(message, "planned failure")
        XCTAssertTrue(store.jobs.first?.canExport == true)
    }

    @MainActor
    func testCancelledRecleanPreservesPreviousStagedResultAndUsesCancelledStatus() async throws {
        let fixture = try TemporaryFixture()
        defer { fixture.remove() }
        let sourceURL = try fixture.write("draft.txt", contents: "draft\u{200B}")
        let engine = RecordingEngine(cleanOutcomes: [
            .success("first-clean"),
            .cancelled,
        ])
        let store = AppStore(
            engine: engine,
            preferences: try makePreferences(),
            stagingRoot: fixture.root.appendingPathComponent("stage")
        )
        await store.addAndInspect([sourceURL])
        let jobID = try XCTUnwrap(store.jobs.first?.id)
        await store.createCopy(jobID: jobID)
        let previousOutputURL = try XCTUnwrap(store.jobs.first?.stagedOutputURL)

        await store.createCopy(jobID: jobID)

        XCTAssertEqual(store.jobs.first?.status, .cancelled)
        XCTAssertEqual(store.jobs.first?.stagedOutputURL, previousOutputURL)
        XCTAssertEqual(try String(contentsOf: previousOutputURL, encoding: .utf8), "first-clean")
        XCTAssertTrue(store.jobs.first?.canExport == true)
        XCTAssertTrue(store.jobs.first?.status.canClean == true)
    }

    @MainActor
    private func makePreferences() throws -> AppPreferences {
        let suiteName = "ProvenanceCleanerStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return AppPreferences(defaults: defaults)
    }
}

private actor RecordingEngine: WatermarkEngine {
    private var allInspections: [String] = []
    private var inspections: [String] = []
    private var cleans: [String] = []
    private var options: [CleaningOptions] = []
    private var activeCleans = 0
    private var maxActiveCleans = 0
    private let cleanDelayNanoseconds: UInt64
    private var cleanOutcomes: [PlannedCleanOutcome]
    private let pdfDeepCleaningIncomplete: Bool

    init(
        cleanDelayNanoseconds: UInt64 = 0,
        cleanOutcomes: [PlannedCleanOutcome] = [],
        pdfDeepCleaningIncomplete: Bool = false
    ) {
        self.cleanDelayNanoseconds = cleanDelayNanoseconds
        self.cleanOutcomes = cleanOutcomes
        self.pdfDeepCleaningIncomplete = pdfDeepCleaningIncomplete
    }

    func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(report: WatermarkReport())
    }

    func inspect(_ input: EngineInput) async throws -> InspectionResult {
        let inputURL = input.inputURL
        allInspections.append(inputURL.lastPathComponent)
        if inputURL.lastPathComponent.hasPrefix("cleaned") {
            return EngineInspection(kind: .text, report: WatermarkReport())
        }
        inspections.append(inputURL.lastPathComponent)
        return EngineInspection(
            kind: .text,
            report: WatermarkReport(
                raw: .object([
                    "suspicious_total": .number(1),
                    "hits": .array([
                        .object([
                            "label": .string("U+200B ZERO WIDTH SPACE"),
                            "kind": .string("strip"),
                            "count": .number(1),
                            "confidence": .string("probable"),
                        ]),
                    ]),
                ])
            )
        )
    }

    func clean(_ input: EngineInput, options: CleanOptions) async throws -> CleanResult {
        let inputURL = input.inputURL
        guard let outputURL = input.outputURL else {
            throw WatermarkEngineError.invalidInput("Missing output URL")
        }
        activeCleans += 1
        maxActiveCleans = max(maxActiveCleans, activeCleans)
        defer { activeCleans -= 1 }
        if cleanDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: cleanDelayNanoseconds)
        }
        cleans.append(inputURL.lastPathComponent)
        self.options.append(options)
        let outcome = cleanOutcomes.isEmpty ? .success("cleaned") : cleanOutcomes.removeFirst()
        switch outcome {
        case let .success(contents):
            try Data(contents.utf8).write(to: outputURL)
        case let .failure(message):
            throw PlannedEngineError(message: message)
        case .cancelled:
            throw WatermarkEngineError.cancelled
        }
        return EngineCleanResult(
            kind: .text,
            outputURL: outputURL,
            report: WatermarkReport(
                raw: .object([
                    "changed": .bool(true),
                    "pdf_deep_clean_incomplete": .bool(pdfDeepCleaningIncomplete),
                    "actions": .array([.string("removed invisible Unicode carrier")]),
                ])
            )
        )
    }

    func cancel(requestID: UUID) async {}

    func allInspectedSourceNames() -> [String] { allInspections }
    func inspectedSourceNames() -> [String] { inspections }
    func cleanedSourceNames() -> [String] { cleans }
    func receivedOptions() -> [CleaningOptions] { options }
    func maximumConcurrentCleans() -> Int { maxActiveCleans }
}

private enum PlannedCleanOutcome: Sendable {
    case success(String)
    case failure(String)
    case cancelled
}

private struct PlannedEngineError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct TemporaryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
