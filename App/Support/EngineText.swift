import Foundation

/// Translates the English sentences the engine puts in its reports.
///
/// The engine's reports stay in English: the app's logic, the technical report
/// and the summary sent for an AI review all read that English. Only the moment
/// of display goes through here, using `EngineText.xcstrings`, whose keys are
/// the engine's sentences. Anything not in the catalog, such as a third-party
/// tool's error or a low-level engine finding, is shown in English as it came.
///
/// A key can hold these placeholders:
/// - `{x}`, `{x2}`: any text, put back exactly as it came. File names and
///   other values from the file go here, so they are never translated.
/// - `{n}`, `{n2}`: a number.
/// - `{t}`: a phrase from the engine's own vocabulary, translated in turn.
/// - `[s]` or `[it|them]`: English word forms that the translation doesn't need.
///
/// Values are inserted in one pass and never used as a format string, so a `%@`
/// or `{x}` inside a file's text stays literal.
struct EngineTextTable: Sendable {
    private struct Template: @unchecked Sendable {
        let expression: NSRegularExpression
        let placeholders: [String]
        let translation: String
    }

    private static let longestInput = 4_000
    private static let longestNesting = 3
    private static var placeholder: Regex<(Substring, Substring?, Substring?, Substring?)> { /\{([xnt])(\d*)\}|\[([^\]]+)\]/ }

    private let exact: [String: String]
    private let templates: [Template]

    init(translations: [String: String]) {
        var exact: [String: String] = [:]
        var templates: [(literal: Int, template: Template)] = []
        for (key, translation) in translations {
            if key.contains("{") || key.contains("[") {
                if let parsed = Self.parse(key, translation: translation) {
                    templates.append(parsed)
                }
            } else {
                exact[key] = translation
            }
        }
        self.exact = exact
        // The template with the most fixed wording wins, whatever order the keys came in.
        self.templates = templates
            .sorted { ($0.literal, $0.template.expression.pattern) > ($1.literal, $1.template.expression.pattern) }
            .map(\.template)
    }

    /// The table for `localization`, read from the compiled catalog.
    init(bundle: Bundle, localization: String) {
        let url = bundle.url(forResource: "EngineText", withExtension: "strings", subdirectory: nil, localization: localization)
        let translations = url.flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        self.init(translations: translations)
    }

    func localized(_ english: String) -> String {
        localized(english, depth: 0)
    }

    private func localized(_ english: String, depth: Int) -> String {
        if let translation = exact[english] { return translation }
        guard depth < Self.longestNesting, english.utf16.count <= Self.longestInput else { return english }
        let whole = NSRange(english.startIndex..., in: english)
        for template in templates {
            guard let match = template.expression.firstMatch(in: english, range: whole) else { continue }
            var values: [String: String] = [:]
            for (index, name) in template.placeholders.enumerated() {
                guard let range = Range(match.range(at: index + 1), in: english) else { continue }
                let value = String(english[range])
                values[name] = name.hasPrefix("t") ? localized(value, depth: depth + 1) : value
            }
            return Self.fill(template.translation, with: values)
        }
        return english
    }

    private static func parse(_ key: String, translation: String) -> (literal: Int, template: Template)? {
        var pattern = "^"
        var placeholders: [String] = []
        var literal = 0
        var rest = Substring(key)
        while let match = rest.firstMatch(of: placeholder) {
            let before = rest[..<match.range.lowerBound]
            pattern += NSRegularExpression.escapedPattern(for: String(before))
            literal += before.count
            if let kind = match.1 {
                placeholders.append("\(kind)\(match.2 ?? "")")
                pattern += kind == "n" ? "([0-9][0-9,]*)" : "(.+?)"
            } else if let forms = match.3 {
                let alternatives = forms.split(separator: "|").map { NSRegularExpression.escapedPattern(for: String($0)) }
                pattern += "(?:" + alternatives.joined(separator: "|") + ")" + (alternatives.count == 1 ? "?" : "")
            }
            rest = rest[match.range.upperBound...]
        }
        pattern += NSRegularExpression.escapedPattern(for: String(rest)) + "$"
        literal += rest.count
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
        return (literal, Template(expression: expression, placeholders: placeholders, translation: translation))
    }

    private static func fill(_ translation: String, with values: [String: String]) -> String {
        var output = ""
        var rest = Substring(translation)
        while let match = rest.firstMatch(of: placeholder) {
            output += rest[..<match.range.lowerBound]
            if let kind = match.1, let value = values["\(kind)\(match.2 ?? "")"] {
                output += value
            } else {
                output += rest[match.range]
            }
            rest = rest[match.range.upperBound...]
        }
        return output + rest
    }
}

enum EngineText {
    /// Nil for English, where the engine's words are shown untouched.
    private static let table: EngineTextTable? = {
        guard !AppLocale.isEnglish, let language = Bundle.main.preferredLocalizations.first else { return nil }
        return EngineTextTable(bundle: .main, localization: language)
    }()

    static func localized(_ english: String) -> String {
        table?.localized(english) ?? english
    }
}
