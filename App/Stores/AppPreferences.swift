import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    enum DeepImageMode: String, CaseIterable, Identifiable {
        case auto
        case never
        case always

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: "Automatic"
            case .never: "Never re-encode"
            case .always: "Always inspect embedded images"
            }
        }
    }

    private enum Key {
        static let acceptedOwnershipNotice = "acceptedOwnershipNotice.v1"
        static let keepNonAIMetadata = "keepNonAIMetadata"
        static let normalizeSpaces = "normalizeSpaces"
        static let alsoLayerAText = "alsoLayerAText"
        static let deepImages = "deepImages"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var acceptedOwnershipNotice: Bool {
        didSet { defaults.set(acceptedOwnershipNotice, forKey: Key.acceptedOwnershipNotice) }
    }

    /// Defaults to preserving ordinary metadata; only AI/provenance-looking
    /// fields are removed unless the user explicitly changes this setting.
    var keepNonAIMetadata: Bool {
        didSet { defaults.set(keepNonAIMetadata, forKey: Key.keepNonAIMetadata) }
    }

    /// Off by default because NBSP and related spacing can be meaningful in
    /// French and other typographic conventions.
    var normalizeSpaces: Bool {
        didSet { defaults.set(normalizeSpaces, forKey: Key.normalizeSpaces) }
    }

    var alsoLayerAText: Bool {
        didSet { defaults.set(alsoLayerAText, forKey: Key.alsoLayerAText) }
    }

    var deepImageMode: DeepImageMode {
        didSet { defaults.set(deepImageMode.rawValue, forKey: Key.deepImages) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.acceptedOwnershipNotice = defaults.bool(forKey: Key.acceptedOwnershipNotice)
        self.keepNonAIMetadata = defaults.object(forKey: Key.keepNonAIMetadata) as? Bool ?? true
        self.normalizeSpaces = defaults.object(forKey: Key.normalizeSpaces) as? Bool ?? false
        self.alsoLayerAText = defaults.object(forKey: Key.alsoLayerAText) as? Bool ?? true
        self.deepImageMode = defaults.string(forKey: Key.deepImages)
            .flatMap(DeepImageMode.init(rawValue:)) ?? .auto
    }

    var cleaningOptions: CleaningOptions {
        CleaningOptions(
            normalizeSpaces: normalizeSpaces,
            keepNonAIMetadata: keepNonAIMetadata,
            stripAllMetadata: !keepNonAIMetadata,
            alsoLayerAText: alsoLayerAText,
            deepImages: deepImageMode.rawValue
        )
    }

    func acceptOwnershipNotice() {
        acceptedOwnershipNotice = true
    }
}
