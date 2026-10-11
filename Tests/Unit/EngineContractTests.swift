import Foundation
import XCTest
@testable import ProvenanceCleaner

final class EngineContractTests: XCTestCase {
    func testUninspectedResultNeverReusesOriginalCredentialVerdict() {
        var job = CleanerJob(sourceURL: URL(fileURLWithPath: "/tmp/original.jpg"))
        job.inspection = WatermarkReport(raw: .object(["has_c2pa": .bool(true)]))
        XCTAssertNotNil(job.currentInspection)
        job.stagedOutputURL = URL(fileURLWithPath: "/tmp/result.jpg")
        XCTAssertNil(job.currentInspection)
    }

    func testUnverifiedC2PAMentionsDoNotBecomeConfirmedFindings() {
        let report = WatermarkReport(raw: .object([
            "findings": .array([.string("C2PA verifier unavailable"), .string("manifest byte-scan")]),
            "c2pa": .object(["inspectionIncomplete": .bool(true)])
        ]))
        XCTAssertFalse(report.hasActionableFindings)
        XCTAssertTrue(report.inspectionIncomplete)
        XCTAssertFalse(report.findings.contains { $0.confidence == .confirmed })
    }

    func testCleanRequestEncodesExactJSONLContractKeys() throws {
        let request = HelperRequest(
            requestID: "request-123",
            operation: .clean,
            inputPath: "/tmp/input.txt",
            outputPath: "/tmp/output.txt",
            options: .conservative
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["requestID", "operation", "inputPath", "outputPath", "options"])
        XCTAssertEqual(object["requestID"] as? String, "request-123")
        XCTAssertEqual(object["operation"] as? String, "clean")
        XCTAssertEqual(object["inputPath"] as? String, "/tmp/input.txt")
        XCTAssertEqual(object["outputPath"] as? String, "/tmp/output.txt")

        let options = try XCTUnwrap(object["options"] as? [String: Any])
        XCTAssertEqual(
            Set(options.keys),
            ["normalizeSpaces", "keepNonAIMetadata", "stripAllMetadata", "alsoLayerAText", "deepImages"]
        )
        XCTAssertEqual(options["normalizeSpaces"] as? Bool, false)
        XCTAssertEqual(options["keepNonAIMetadata"] as? Bool, true)
        XCTAssertEqual(options["stripAllMetadata"] as? Bool, false)
        XCTAssertEqual(options["alsoLayerAText"] as? Bool, true)
        XCTAssertEqual(options["deepImages"] as? String, "auto")
    }

    func testCapabilitiesRequestOmitsUnusedOptionalKeys() throws {
        let data = try JSONEncoder().encode(
            HelperRequest(requestID: "cap-1", operation: .capabilities)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["requestID", "operation"])
    }

    func testResponsePreservesUnknownReportFields() throws {
        let data = Data(
            #"{"requestID":"i-1","ok":true,"kind":"image","report":{"has_c2pa":true,"future_field":{"score":0.91},"findings":["C2PA manifest"],"findings_confidence":["confirmed"]}}"#.utf8
        )

        let response = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertEqual(response.watermarkKind, .image)
        XCTAssertEqual(response.report["future_field"]?["score"]?.numberValue, 0.91)

        let report = WatermarkReport(raw: response.report)
        XCTAssertTrue(report.hasActionableFindings)
        XCTAssertEqual(report.findings.first?.confidence, .confirmed)
    }

    func testResponseRejectsMissingRequiredEnvelopeFields() throws {
        let missingKind = Data(#"{"requestID":"i-1","ok":true,"report":{}}"#.utf8)
        let missingReport = Data(#"{"requestID":"i-1","ok":true,"kind":"text"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HelperResponse.self, from: missingKind))
        XCTAssertThrowsError(try JSONDecoder().decode(HelperResponse.self, from: missingReport))
    }

    func testResponseRejectsMalformedStrictEnvelopeValues() throws {
        let malformedResponses = [
            #"{"requestID":"","ok":true,"kind":"text","report":{}}"#,
            #"{"requestID":"i-1","ok":true,"kind":"","report":{}}"#,
            #"{"requestID":"i-1","ok":true,"kind":"text","report":[]}"#,
            #"{"requestID":"i-1","ok":true,"kind":"text","report":{},"error":"unexpected"}"#,
            #"{"requestID":"i-1","ok":false,"kind":"invalid_input","report":{}}"#,
            #"{"requestID":"i-1","ok":false,"kind":"invalid_input","report":{},"error":""}"#,
        ]

        for json in malformedResponses {
            XCTAssertThrowsError(
                try JSONDecoder().decode(HelperResponse.self, from: Data(json.utf8)),
                "Expected strict response decoding to reject: \(json)"
            )
        }
    }

    func testResponseAcceptsStrictFailureEnvelope() throws {
        let data = Data(
            #"{"requestID":"e-1","ok":false,"kind":"invalid_input","report":{"details":{"field":"inputPath"}},"error":"inputPath is required"}"#.utf8
        )

        let response = try JSONDecoder().decode(HelperResponse.self, from: data)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.kind, "invalid_input")
        XCTAssertEqual(response.error, "inputPath is required")
        XCTAssertEqual(response.report["details"]?["field"]?.stringValue, "inputPath")
    }

    func testEnvironmentOverrideResolvesPythonHelper() async throws {
        let expected = URL(fileURLWithPath: "/tmp/provenance-helper.py")
        let engine = BundledWatermarkEngine(
            bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
            environment: [BundledWatermarkEngine.helperOverrideEnvironmentKey: expected.path]
        )

        let resolved = try await engine.resolvedHelperURL()
        XCTAssertEqual(resolved, expected)
    }

    func testLongLivedHelperServesMultipleRequestsFromOneProcess() async throws {
        let temporaryDirectory = try makeTemporaryDirectory(prefix: "ProvenanceCleanerSessionTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let helperURL = temporaryDirectory.appendingPathComponent("session-helper")
        try writeExecutable(
            """
            #!/bin/sh
            while IFS= read -r request; do
              request_id=$(/bin/echo "$request" | /usr/bin/sed -E 's/.*"requestID":"([^"]+)".*/\\1/')
              /usr/bin/printf '{"requestID":"%s","ok":true,"kind":"capabilities","report":{"pid":%s}}\\n' "$request_id" "$$"
            done
            """,
            to: helperURL
        )

        let engine = BundledWatermarkEngine(helperURL: helperURL)
        let first = try await engine.capabilities()
        let second = try await engine.capabilities()

        XCTAssertEqual(first.report.raw["pid"]?.numberValue, second.report.raw["pid"]?.numberValue)
    }

    func testEngineStagesInputAndNeverPassesOriginalPathToHelper() async throws {
        let temporaryDirectory = try makeTemporaryDirectory(prefix: "ProvenanceCleanerStageTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let originalURL = temporaryDirectory.appendingPathComponent("original.txt")
        let requestedOutputURL = temporaryDirectory.appendingPathComponent("review.cleaned.txt")
        let originalBytes = Data("owned\u{200B}content".utf8)
        try originalBytes.write(to: originalURL)

        let helperURL = temporaryDirectory.appendingPathComponent("staging-helper.py")
        try writeExecutable(
            """
            #!/usr/bin/python3
            import json
            import os
            import shutil
            import sys

            for line in sys.stdin:
                request = json.loads(line)
                input_path = request["inputPath"]
                output_path = request["outputPath"]
                shutil.copyfile(input_path, output_path)
                response = {
                    "requestID": request["requestID"],
                    "ok": True,
                    "kind": "text",
                    "report": {
                        "sawOriginal": input_path == os.environ["EXPECTED_ORIGINAL"],
                        "helperInput": input_path,
                    },
                    "outputPath": output_path,
                }
                print(json.dumps(response, separators=(",", ":")), flush=True)
            """,
            to: helperURL
        )
        let engine = BundledWatermarkEngine(
            helperURL: helperURL,
            environment: ["PATH": "/usr/bin:/bin", "EXPECTED_ORIGINAL": originalURL.path]
        )

        let result = try await engine.clean(
            EngineInput(inputURL: originalURL, outputURL: requestedOutputURL),
            options: .conservative
        )

        XCTAssertEqual(result.outputURL, requestedOutputURL)
        XCTAssertEqual(result.report.raw["sawOriginal"]?.boolValue, false)
        XCTAssertNotEqual(result.report.raw["helperInput"]?.stringValue, originalURL.path)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: requestedOutputURL), originalBytes)
    }

    func testCancelTerminatesMatchingHelperProcess() async throws {
        let temporaryDirectory = try makeTemporaryDirectory(prefix: "ProvenanceCleanerCancelTests")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let helperURL = temporaryDirectory.appendingPathComponent("blocking-helper")
        let markerURL = temporaryDirectory.appendingPathComponent("first-process-started")
        let script = """
        #!/bin/sh
        while IFS= read -r request; do
          if [ ! -f "$RESTART_MARKER" ]; then
            /usr/bin/touch "$RESTART_MARKER"
            exec /bin/sleep 30
          else
            request_id=$(/bin/echo "$request" | /usr/bin/sed -E 's/.*"requestID":"([^"]+)".*/\\1/')
            /usr/bin/printf '{"requestID":"%s","ok":true,"kind":"capabilities","report":{"restarted":true}}\\n' "$request_id"
          fi
        done
        """
        try writeExecutable(script, to: helperURL)

        let engine = BundledWatermarkEngine(
            helperURL: helperURL,
            environment: ["PATH": "/usr/bin:/bin", "RESTART_MARKER": markerURL.path]
        )
        let requestID = UUID()
        let requestTask = Task {
            try await engine.capabilities(requestID: requestID)
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: markerURL.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        await engine.cancel(requestID: requestID)

        do {
            _ = try await requestTask.value
            XCTFail("Expected the terminated helper request to be cancelled")
        } catch let error as WatermarkEngineError {
            XCTAssertEqual(error, .cancelled)
        }

        let restarted = try await engine.capabilities()
        XCTAssertEqual(restarted.report.raw["restarted"]?.boolValue, true)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}

final class TextDiffTests: XCTestCase {
    func testReplacementMarksRemovedAndInsertedCharacters() {
        let result = TextDiffEngine.compare(
            original: "prefix old suffix",
            cleaned: "prefix new suffix"
        )

        XCTAssertEqual(changedText(in: result.originalSegments, kind: .removed), "old")
        XCTAssertEqual(changedText(in: result.cleanedSegments, kind: .inserted), "new")
        XCTAssertEqual(result.removedCodePointCount, 3)
        XCTAssertEqual(result.insertedCodePointCount, 3)
        XCTAssertEqual(result.originalVisibleText, "prefix old suffix")
        XCTAssertEqual(result.cleanedVisibleText, "prefix new suffix")
        XCTAssertFalse(result.wasTruncated)
        XCTAssertFalse(result.usedSimplifiedDiff)
    }

    func testInvisibleCharacterRemovalRemainsAnExactCharacterDiff() {
        let result = TextDiffEngine.compare(
            original: "a\u{200B}b",
            cleaned: "ab"
        )

        XCTAssertEqual(changedText(in: result.originalSegments, kind: .removed), "\u{200B}")
        XCTAssertEqual(changedText(in: result.cleanedSegments, kind: .inserted), "")
        XCTAssertEqual(result.removedCodePointCount, 1)
        XCTAssertEqual(result.insertedCodePointCount, 0)
    }

    func testCanonicallyEquivalentSpellingsRemainDistinctScalarDiffs() {
        let original = "caf\u{00E9}"
        let cleaned = "cafe\u{0301}"
        let result = TextDiffEngine.compare(
            original: original,
            cleaned: cleaned
        )

        XCTAssertEqual(scalarValues(in: result.originalVisibleText), scalarValues(in: original))
        XCTAssertEqual(scalarValues(in: result.cleanedVisibleText), scalarValues(in: cleaned))
        XCTAssertEqual(
            scalarValues(in: changedText(in: result.originalSegments, kind: .removed)),
            [0x00E9]
        )
        XCTAssertEqual(
            scalarValues(in: changedText(in: result.cleanedSegments, kind: .inserted)),
            [0x0065, 0x0301]
        )
        XCTAssertEqual(result.removedCodePointCount, 1)
        XCTAssertEqual(result.insertedCodePointCount, 2)
    }

    func testVariationSelectorRemovalIsDetectedExactly() {
        let result = TextDiffEngine.compare(
            original: "A\u{FE0F}",
            cleaned: "A"
        )

        XCTAssertEqual(
            scalarValues(in: changedText(in: result.originalSegments, kind: .removed)),
            [0xFE0F]
        )
        XCTAssertEqual(result.removedCodePointCount, 1)
        XCTAssertEqual(result.insertedCodePointCount, 0)
    }

    func testLineEndingChangePreservesBothVisibleRepresentations() {
        let original = "first\r\nsecond"
        let cleaned = "first\nsecond"
        let result = TextDiffEngine.compare(original: original, cleaned: cleaned)

        XCTAssertEqual(scalarValues(in: result.originalVisibleText), scalarValues(in: original))
        XCTAssertEqual(scalarValues(in: result.cleanedVisibleText), scalarValues(in: cleaned))
        XCTAssertEqual(
            scalarValues(in: changedText(in: result.originalSegments, kind: .removed)),
            [0x000D]
        )
    }

    func testIdenticalTextProducesNoChanges() {
        let result = TextDiffEngine.compare(
            original: "unchanged\ntext",
            cleaned: "unchanged\ntext"
        )

        XCTAssertFalse(result.hasChanges)
        XCTAssertEqual(result.originalSegments, [
            TextDiffSegment(text: "unchanged\ntext", kind: .unchanged),
        ])
        XCTAssertEqual(result.cleanedSegments, result.originalSegments)
    }

    func testLargeChangedRegionUsesExplicitComparisonLimit() {
        let result = TextDiffEngine.compare(
            original: "abcdefgh",
            cleaned: "12345678",
            limits: TextDiffLimits(
                maximumVisibleCodePointsPerSide: 50,
                maximumChangedCodePointsPerSide: 3
            )
        )

        XCTAssertTrue(result.wasTruncated)
        XCTAssertEqual(result.originalVisibleText, "abc")
        XCTAssertEqual(result.cleanedVisibleText, "123")
        XCTAssertEqual(result.removedCodePointCount, 3)
        XCTAssertEqual(result.insertedCodePointCount, 3)
    }

    func testComparisonWorkLimitFallsBackToChangedBlocks() {
        let result = TextDiffEngine.compare(
            original: "abc",
            cleaned: "123",
            limits: TextDiffLimits(
                maximumVisibleCodePointsPerSide: 50,
                maximumChangedCodePointsPerSide: 50,
                maximumDetailedComparisonWork: 4
            )
        )

        XCTAssertTrue(result.usedSimplifiedDiff)
        XCTAssertFalse(result.wasTruncated)
        XCTAssertEqual(result.originalSegments, [
            TextDiffSegment(text: "abc", kind: .removed),
        ])
        XCTAssertEqual(result.cleanedSegments, [
            TextDiffSegment(text: "123", kind: .inserted),
        ])
    }

    func testSummaryLabelsInterpolateCounts() {
        XCTAssertEqual(TextDiffSummary.removedLabel(for: 1), "1 code point removed")
        XCTAssertEqual(TextDiffSummary.removedLabel(for: 3), "3 code points removed")
        XCTAssertEqual(TextDiffSummary.insertedLabel(for: 1), "1 code point inserted")
        XCTAssertEqual(TextDiffSummary.insertedLabel(for: 3), "3 code points inserted")
    }

    func testTruncatedUTF8PreviewDropsOnlyAnIncompleteTrailingScalar() {
        let completeBytes = Data("A€".utf8)
        let truncatedBytes = Data(completeBytes.dropLast())

        let decoded = UTF8PreviewDecoder.decode(
            truncatedBytes,
            trimmingIncompleteTrailingSequence: true
        )

        XCTAssertEqual(scalarValues(in: decoded), [0x0041])
    }

    private func changedText(
        in segments: [TextDiffSegment],
        kind: TextDiffSegment.Kind
    ) -> String {
        segments
            .filter { $0.kind == kind }
            .map(\.text)
            .joined()
    }

    private func scalarValues(in text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }
}
