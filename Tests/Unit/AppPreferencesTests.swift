import Foundation
import XCTest
@testable import ProvenanceCleaner

final class AppPreferencesTests: XCTestCase {
    @MainActor
    func testConservativeDefaultsPreserveMetadataAndSpaces() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)

        XCTAssertTrue(preferences.keepNonAIMetadata)
        XCTAssertFalse(preferences.normalizeSpaces)
        XCTAssertTrue(preferences.alsoLayerAText)
        XCTAssertEqual(preferences.deepImageMode, .auto)
        XCTAssertEqual(preferences.cleaningOptions, .conservative)
    }

    @MainActor
    func testChoicesPersistAcrossPreferenceInstances() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppPreferences(defaults: defaults)
        first.acceptedOwnershipNotice = true
        first.keepNonAIMetadata = false
        first.normalizeSpaces = true
        first.deepImageMode = .never

        let second = AppPreferences(defaults: defaults)
        XCTAssertTrue(second.acceptedOwnershipNotice)
        XCTAssertFalse(second.keepNonAIMetadata)
        XCTAssertTrue(second.normalizeSpaces)
        XCTAssertEqual(second.deepImageMode, .never)
        XCTAssertTrue(second.cleaningOptions.stripAllMetadata)
    }

    @MainActor
    func testWordChoicesPersistAndEncodeSeparatelyFromNormalCleaning() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.wordSessionMode, .randomize)
        XCTAssertEqual(preferences.wordDateMode, .keep)
        XCTAssertNil(preferences.cleaningOptions.wordTraces)
        preferences.wordSessionMode = .remove
        preferences.wordDateMode = .randomize
        preferences.wordDateStart = Date(timeIntervalSince1970: 1_577_836_800)
        preferences.wordDateEnd = Date(timeIntervalSince1970: 1_580_515_200)
        preferences.wordResetArchiveDates = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.wordTraceOptions, preferences.wordTraceOptions)
        XCTAssertTrue(restored.wordDateRangeValid)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.wordTraceOptions)) as? [String: Any])
        XCTAssertEqual(json["start"] as? String, "2020-01-01T00:00:00Z")
        XCTAssertEqual(json["rsids"] as? String, "remove")
        restored.wordDateEnd = restored.wordDateStart
        XCTAssertFalse(restored.wordDateRangeValid)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ProvenanceCleanerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @MainActor
    func testLosslessPDFChoicePersistsAndReachesHelperOptions() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = AppPreferences(defaults: defaults)
        first.deepImageMode = .lossless
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.deepImageMode, .lossless)
        let request = HelperRequest(operation: .clean, inputPath: "/tmp/input.pdf", outputPath: "/tmp/output.pdf", options: restored.cleaningOptions)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual((json["options"] as? [String: Any])?["deepImages"] as? String, "lossless")
    }
}
