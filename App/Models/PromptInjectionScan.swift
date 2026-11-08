import Foundation

/// The engine's prompt-injection report: signs of instructions hidden from a
/// person but readable by an AI assistant that later processes the file.
struct PromptInjectionScan: Equatable, Sendable {
    enum Verdict: String, Sendable {
        case none, suspicious, likely

        var title: String {
            switch self {
            case .none: "No signs found"
            case .suspicious: "Suspicious"
            case .likely: "Signs of prompt injection"
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

        var techniqueTitle: String {
            switch technique {
            case "smuggled_text": "Hidden messages"
            case "hidden_text": "Hidden text"
            case "instruction_phrase": "Instruction-like wording"
            case "invisible_characters": "Invisible characters"
            case "bidi_control": "Text-direction controls"
            case "exfiltration_url": "Suspicious web addresses"
            case "encoded_text": "Encoded text"
            case "mixed_script": "Lookalike letters"
            default: "Other signs"
            }
        }
    }

    let raw: JSONValue

    var available: Bool { raw["available"]?.boolValue == true }
    var reason: String { raw["reason"]?.stringValue ?? "This file couldn't be checked." }
    var verdict: Verdict { raw["verdict"]?.stringValue.flatMap(Verdict.init(rawValue:)) ?? .none }
    var notes: [String] { raw["notes"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    var findingsTotal: Int { Int(raw["findingsTotal"]?.numberValue ?? Double(findings.count)) }
    var extractedCharacters: Int { Int(raw["extracted"]?["chars"]?.numberValue ?? 0) }
    var reviewText: String { raw["review_text"]?.stringValue ?? "" }

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

    var lesserFindings: [Finding] {
        findings.filter { $0.severity == .info }
    }
}

enum InjectionScanState: Equatable, Sendable {
    case notScanned
    case scanning
    case finished(PromptInjectionScan)
    case failed(String)
}
