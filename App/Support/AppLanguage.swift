import AppKit
import Foundation

/// A language the app's interface can use. `system` means no override: macOS
/// picks the best match from the user's preferred languages.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case spanish = "es"

    /// The per-app preference macOS itself reads at launch, and the one
    /// System Settings > Language & Region > Applications writes. Using it
    /// keeps menus, system panels and the app's own text in one language.
    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Languages are named in their own language, so a person who can't read
    /// the current one can still find theirs.
    var displayName: String {
        switch self {
        case .system: String(localized: "System default")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .spanish: "Español"
        }
    }

    /// The choice a stored language list stands for. A language this app
    /// doesn't offer counts as `system`, because macOS falls back from it.
    init(preferredLanguages: [String]?) {
        guard let first = preferredLanguages?.first else {
            self = .system
            return
        }
        let language = Locale.Language(identifier: first)
        switch language.languageCode?.identifier {
        case "en":
            self = .english
        case "zh" where language.maximalIdentifier.hasPrefix("zh-Hans"):
            self = .simplifiedChinese
        case "zh" where language.maximalIdentifier.hasPrefix("zh-Hant"):
            self = .traditionalChinese
        case "ja":
            self = .japanese
        case "es":
            self = .spanish
        default:
            self = .system
        }
    }
}

/// The locale for dates and lists: the language the app is showing, with the
/// user's region. `Locale.current` alone can keep the system's language after
/// a per-app override.
enum AppLocale {
    static let current = resolve(language: Bundle.main.preferredLocalizations.first ?? "en", system: .autoupdatingCurrent)

    static var isEnglish: Bool { current.language.languageCode?.identifier == "en" }

    /// Joins items in running text: ", " in English, "、" in Chinese.
    static var listSeparator: String { String(localized: "list.separator", defaultValue: ", ") }

    static func resolve(language: String, system: Locale) -> Locale {
        if language.hasPrefix("en"), system.language.languageCode?.identifier == "en" {
            return system
        }
        guard let region = system.region?.identifier else { return Locale(identifier: language) }
        return Locale(identifier: "\(language)_\(region)")
    }

    /// "A, B and C" as the chosen language writes a list.
    static func list(_ items: [String]) -> String {
        items.formatted(.list(type: .and).locale(current))
    }
}

/// Starts a new copy of the app and quits this one. A language change needs a
/// fresh launch so that every menu, panel and string changes together.
@MainActor
enum AppRelauncher {
    static func relaunch(onFailure: @escaping @MainActor (String) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    onFailure(message)
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
