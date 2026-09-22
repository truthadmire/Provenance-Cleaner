import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    enum DeepImageMode: String, CaseIterable, Identifiable {
        case auto
        case lossless
        case always
        case never

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: "Automatic"
            case .lossless: "Lossless pass only"
            case .always: "Deep clean every PDF"
            case .never: "Document metadata only"
            }
        }

        var explanation: String {
            switch self {
            case .auto:
                "Clean document metadata first, then embedded images only when provenance markers remain. Images may be re-encoded if needed."
            case .lossless:
                "Run the pass-through image pass without escalating to lossy re-encoding. JPEG and JPEG2000 data is passed through where supported; other codecs may be rewritten. Some metadata may remain."
            case .always:
                "Deep-clean every PDF, including ordinary camera and editor metadata inside images. Images may be re-encoded if needed."
            case .never:
                "Clean document metadata only. Skip the embedded-image pass and preserve the image streams."
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

    var wordSessionMode: WordTraceMode {
        didSet { defaults.set(wordSessionMode.rawValue, forKey: "wordSessionMode") }
    }
    var wordDateMode: WordTraceMode {
        didSet { defaults.set(wordDateMode.rawValue, forKey: "wordDateMode") }
    }
    var wordDateStart: Date {
        didSet { defaults.set(wordDateStart, forKey: "wordDateStart") }
    }
    var wordDateEnd: Date {
        didSet { defaults.set(wordDateEnd, forKey: "wordDateEnd") }
    }
    var wordResetArchiveDates: Bool {
        didSet { defaults.set(wordResetArchiveDates, forKey: "wordResetArchiveDates") }
    }

    var wordTraceOptions: WordTraceOptions {
        let formatter = ISO8601DateFormatter()
        return WordTraceOptions(
            rsids: wordSessionMode, dates: wordDateMode,
            start: wordDateMode == .randomize ? formatter.string(from: wordDateStart) : "",
            end: wordDateMode == .randomize ? formatter.string(from: wordDateEnd) : "",
            resetArchiveDates: wordResetArchiveDates
        )
    }

    var wordDateRangeValid: Bool {
        wordDateMode != .randomize || wordDateStart < wordDateEnd
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.wordSessionMode = defaults.string(forKey: "wordSessionMode").flatMap(WordTraceMode.init(rawValue:)) ?? .randomize
        self.wordDateMode = defaults.string(forKey: "wordDateMode").flatMap(WordTraceMode.init(rawValue:)) ?? .keep
        self.wordDateStart = defaults.object(forKey: "wordDateStart") as? Date ?? Date().addingTimeInterval(-30 * 86400)
        self.wordDateEnd = defaults.object(forKey: "wordDateEnd") as? Date ?? Date()
        self.wordResetArchiveDates = defaults.bool(forKey: "wordResetArchiveDates")
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
