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
            case .auto: String(localized: "Automatic")
            case .lossless: String(localized: "Lossless pass only")
            case .always: String(localized: "Deep clean every PDF")
            case .never: String(localized: "Document metadata only")
            }
        }

        var explanation: String {
            switch self {
            case .auto:
                String(localized: "Clean document metadata first, then embedded images only when provenance markers remain. Images may be re-encoded if needed.")
            case .lossless:
                String(localized: "Run the pass-through image pass without escalating to lossy re-encoding. JPEG and JPEG2000 data is passed through where supported; other codecs may be rewritten. Some metadata may remain.")
            case .always:
                String(localized: "Deep-clean every PDF, including ordinary camera and editor metadata inside images. Images may be re-encoded if needed.")
            case .never:
                String(localized: "Clean document metadata only. Skip the embedded-image pass and preserve the image streams.")
            }
        }
    }

    private enum Key {
        static let acceptedOwnershipNotice = "acceptedOwnershipNotice.v1"
        static let keepNonAIMetadata = "keepNonAIMetadata"
        static let normalizeSpaces = "normalizeSpaces"
        static let alsoLayerAText = "alsoLayerAText"
        static let deepImages = "deepImages"
        static let aiProviders = "aiProviders"
    }

    /// The language the running app chose at launch, compared with `language`
    /// to tell whether a relaunch is still needed.
    let launchLanguage: AppLanguage

    @ObservationIgnored private let defaults: UserDefaults

    /// Kept in the per-app `AppleLanguages` preference, the one macOS reads at
    /// launch. "System default" removes it, leaving no override behind.
    var language: AppLanguage {
        didSet {
            if language == .system {
                defaults.removeObject(forKey: AppLanguage.defaultsKey)
            } else {
                defaults.set([language.rawValue], forKey: AppLanguage.defaultsKey)
            }
        }
    }

    var languageNeedsRelaunch: Bool { language != launchLanguage }

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

    /// Models and regions by provider. API keys are in the Keychain, not here.
    private var aiProviderSettings: [String: AIProviderSettings] {
        didSet {
            if let data = try? JSONEncoder().encode(aiProviderSettings) {
                defaults.set(data, forKey: Key.aiProviders)
            }
        }
    }

    func aiSettings(for provider: AIProvider) -> AIProviderSettings {
        aiProviderSettings[provider.rawValue] ?? .defaults(for: provider)
    }

    func setAISettings(_ settings: AIProviderSettings, for provider: AIProvider) {
        aiProviderSettings[provider.rawValue] = settings
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

    /// - Parameter languageDomain: the preferences domain to read the language
    ///   override from. It has to be read from the domain itself: a plain lookup
    ///   of `AppleLanguages` would also find the system-wide list.
    init(defaults: UserDefaults = .standard, languageDomain: String? = nil) {
        self.defaults = defaults
        let domain = languageDomain ?? (defaults === UserDefaults.standard ? Bundle.main.bundleIdentifier : nil)
        let stored = domain.flatMap { defaults.persistentDomain(forName: $0)?[AppLanguage.defaultsKey] as? [String] }
        self.language = AppLanguage(preferredLanguages: stored)
        self.launchLanguage = AppLanguage(preferredLanguages: stored)
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
        self.aiProviderSettings = defaults.data(forKey: Key.aiProviders)
            .flatMap { try? JSONDecoder().decode([String: AIProviderSettings].self, from: $0) } ?? [:]
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
