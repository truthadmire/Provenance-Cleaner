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

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ProvenanceCleanerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
