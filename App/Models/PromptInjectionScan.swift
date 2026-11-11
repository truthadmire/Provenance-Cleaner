import Foundation

/// The engine's prompt-injection report: signs of instructions hidden from a
/// person but readable by an AI assistant that later processes the file.
struct PromptInjectionScan: Equatable, Sendable {
    enum Verdict: String, Sendable {
        case none, suspicious, likely

        var title: String {
            switch self {
            case .none: String(localized: "No signs found")
            case .suspicious: String(localized: "Suspicious")
            case .likely: String(localized: "Signs of prompt injection")
            }
        }
    }

    enum Severity: String, Sendable {
        case high, medium, info
    }

    struct Finding: Equatable, Sendable, Identifiable {
        let id: Int
        let technique: String
        let severity: Severity
        let location: String
        let summary: String
        let excerpt: String
        let decoded: String?

        /// `summary` and `location` stay the engine's English: that's what an
        /// AI review is told. These are for display only.
        var localizedSummary: String { EngineText.localized(summary) }
        var localizedLocation: String { EngineText.localized(location) }

        var techniqueTitle: String {
            switch technique {
            case "smuggled_text": String(localized: "Hidden messages")
            case "hidden_text": String(localized: "Hidden text")
            case "instruction_phrase": String(localized: "Instruction-like wording")
            case "invisible_characters": String(localized: "Invisible characters")
            case "bidi_control": String(localized: "Text-direction controls")
            case "exfiltration_url": String(localized: "Suspicious web addresses")
            case "encoded_text": String(localized: "Encoded text")
            case "mixed_script": String(localized: "Lookalike letters")
            default: String(localized: "Other signs")
            }
        }
    }

    let raw: JSONValue

    var available: Bool { raw["available"]?.boolValue == true }
    var reason: String { raw["reason"]?.stringValue.map(EngineText.localized) ?? String(localized: "This file couldn't be checked.") }
    var verdict: Verdict { raw["verdict"]?.stringValue.flatMap(Verdict.init(rawValue:)) ?? .none }
    var notes: [String] { raw["notes"]?.arrayValue?.compactMap(\.stringValue).map(EngineText.localized) ?? [] }
    var findingsTotal: Int { Int(raw["findingsTotal"]?.numberValue ?? Double(findings.count)) }
    var extractedCharacters: Int { Int(raw["extracted"]?["chars"]?.numberValue ?? 0) }
    var reviewText: String { raw["review_text"]?.stringValue ?? "" }
    var reviewTextTruncated: Bool { raw["extracted"]?["truncated"]?.boolValue == true }

    var findings: [Finding] {
        (raw["findings"]?.arrayValue ?? []).enumerated().compactMap { index, item in
            guard let technique = item["technique"]?.stringValue,
                  let severity = item["severity"]?.stringValue.flatMap(Severity.init(rawValue:)),
                  let summary = item["summary"]?.stringValue
            else { return nil }
            return Finding(
                id: index,
                technique: technique,
                severity: severity,
                location: item["location"]?.stringValue ?? "",
                summary: summary,
                excerpt: item["excerpt"]?.stringValue ?? "",
                decoded: item["decoded"]?.stringValue
            )
        }
    }

    /// Findings that bear on the verdict, by technique, most severe technique first.
    var mainGroups: [(title: String, findings: [Finding])] {
        var groups: [(title: String, findings: [Finding])] = []
        for finding in findings where finding.severity != .info {
            if let index = groups.firstIndex(where: { $0.title == finding.techniqueTitle }) {
                groups[index].findings.append(finding)
            } else {
                groups.append((finding.techniqueTitle, [finding]))
            }
        }
        return groups
    }

    var decodedMessages: [String] {
        findings.compactMap(\.decoded)
    }

    var lesserFindings: [Finding] {
        findings.filter { $0.severity == .info }
    }
}

/// One provider's AI review of a file. Kept in memory only, never written to disk.
struct AIProviderReview: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running
        case finished(AIReviewOutcome)
        case failed(String)
    }

    let provider: AIProvider
    let model: String
    var state: State

    var id: AIProvider { provider }
}

enum InjectionScanState: Equatable, Sendable {
    case notScanned
    case scanning
    case finished(PromptInjectionScan)
    case failed(String)
}
