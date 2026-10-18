import XCTest
@testable import ProvenanceCleaner

final class ReportPresentationTests: XCTestCase {
    func testIncompleteOfficeInspectionNamesTheUncheckedEmbeddedFile() {
        // Shape of a real report for a DOCX whose embedded binary c2patool can't read.
        let report = WatermarkReport(raw: .object([
            "c2pa": .object([
                "state": .string("inconclusive"),
                "inspectionIncomplete": .bool(true),
                "isContainer": .bool(true),
                "document": .object(["state": .string("absent"), "inspectionIncomplete": .bool(false)]),
                "embeddedAssets": .array([
                    .object([
                        "path": .string("word/media/keep.bin"),
                        "state": .string("unsupported"),
                        "inspectionIncomplete": .bool(true),
                        "error": .string("Error: Unsupported file type"),
                    ]),
                ]),
            ]),
        ]))

        XCTAssertTrue(report.inspectionIncomplete)
        XCTAssertEqual(
            report.incompleteReasons,
            ["word/media/keep.bin couldn't be checked for content credentials (unsupported file type)."]
        )
    }

    func testIncompleteReportAlwaysHasAReason() {
        let report = WatermarkReport(raw: .object([
            "tools": .object(["exiftool": .object(["available": .bool(false)])]),
        ]))
        XCTAssertTrue(report.inspectionIncomplete)
        XCTAssertEqual(report.incompleteReasons, ["exiftool isn't available, so its checks didn't run."])

        let complete = WatermarkReport(raw: .object(["findings": .array([])]))
        XCTAssertFalse(complete.inspectionIncomplete)
        XCTAssertTrue(complete.incompleteReasons.isEmpty)
    }

    func testRepeatedListItemsAreShownOnce() {
        let finding = WatermarkFinding(
            message: "JPEG APP11: c2pa, C2PA, digitalSourceType, algorithmicMedia, c2pa, C2PA, jumb, JUMB",
            confidence: .confirmed
        )
        XCTAssertEqual(finding.displayMessage, "JPEG APP11: c2pa, digitalSourceType, algorithmicMedia, jumb")

        let plain = WatermarkFinding(message: "frontmatter key: generator", confidence: .probable)
        XCTAssertEqual(plain.displayMessage, "frontmatter key: generator")
    }

    func testFindingsAreGroupedByWhatTheyAreAbout() {
        XCTAssertEqual(FindingCategory.classify("c2patool reports a C2PA-related manifest"), .credentials)
        XCTAssertEqual(FindingCategory.classify("frontmatter key: ai_generated"), .metadata)
        XCTAssertEqual(FindingCategory.classify("layer-a: U+200B ZERO WIDTH SPACE (Cf) x1"), .invisibleText)
        XCTAssertEqual(FindingCategory.classify("Something new from a future engine"), .other)

        let report = WatermarkReport(raw: .object([
            "hits": .array([.object(["label": .string("U+00AD SOFT HYPHEN"), "count": .number(1)])]),
        ]))
        XCTAssertEqual(report.findings.first?.category, .invisibleText)
    }

    func testInformationalLeftoversAreNotRemainingMarkers() {
        // A cleaned text copy that keeps a typographic ideographic space.
        let copy = WatermarkReport(raw: .object([
            "suspicious_total": .number(1),
            "hits": .array([.object([
                "label": .string("U+3000 IDEOGRAPHIC SPACE (Zs)"),
                "confidence": .string("informational"),
                "count": .number(1),
            ])]),
        ]))
        XCTAssertFalse(copy.hasActionableFindings)
        XCTAssertEqual(
            AppStore.resultStatus(postInspection: copy, postInspectionCompleted: true, cleanReport: nil),
            .readyToExport(residualCount: 0)
        )

        let unitemised = WatermarkReport(raw: .object(["suspicious_total": .number(2)]))
        XCTAssertTrue(unitemised.hasActionableFindings)
    }

    func testTextCleanStatisticsBecomeChangeDescriptions() {
        let report = WatermarkReport(raw: .object([
            "stats": .object([
                "removed": .object(["U+200B ZERO WIDTH SPACE (Cf)": .number(2)]),
                "replaced": .object([:]),
                "removed_count": .number(2),
            ]),
        ]))
        XCTAssertEqual(report.changeDescriptions, ["Removed U+200B ZERO WIDTH SPACE (Cf) ×2"])
    }

    func testVerdictExplainsAnIncompleteCheck() {
        var job = CleanerJob(sourceURL: URL(fileURLWithPath: "/tmp/report.docx"))
        job.inspection = WatermarkReport(raw: .object([
            "tools": .object(["c2patool": .object(["error": .string("Error: timed out")])]),
        ]))
        job.status = .inspectionIncomplete(0)

        let verdict = JobVerdict(job: job)

        XCTAssertEqual(verdict.tone, .warning)
        XCTAssertEqual(verdict.title, "Checking didn't finish")
        XCTAssertEqual(verdict.message, "c2patool: timed out")
    }

    func testVerdictNeverCallsAnUncheckedCopyClean() {
        var job = CleanerJob(sourceURL: URL(fileURLWithPath: "/tmp/photo.jpg"))
        job.stagedOutputURL = URL(fileURLWithPath: "/tmp/stage/cleaned.jpg")
        job.status = .cleanedInspectionIncomplete

        let verdict = JobVerdict(job: job)

        XCTAssertEqual(verdict.tone, .warning)
        XCTAssertEqual(verdict.title, "Your copy is ready, but checking it didn't finish")
    }
}
