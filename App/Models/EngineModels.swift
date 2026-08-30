import Foundation

enum WatermarkKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case container
    case av
    case unknown

    var displayName: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .container: "Document"
        case .av: "Audio or video"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "doc.text"
        case .image: "photo"
        case .container: "doc.richtext"
        case .av: "play.rectangle"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

struct CleaningOptions: Codable, Equatable, Sendable {
    var normalizeSpaces: Bool
    var keepNonAIMetadata: Bool
    var stripAllMetadata: Bool
    var alsoLayerAText: Bool
    var deepImages: String

    static let conservative = CleaningOptions(
        normalizeSpaces: false,
        keepNonAIMetadata: true,
        stripAllMetadata: false,
        alsoLayerAText: true,
        deepImages: "auto"
    )
}

/// A single engine request. The request identifier is stable across the
/// Swift/JSONL boundary so cancellation can terminate the matching operation.
struct EngineInput: Equatable, Sendable {
    var requestID: UUID
    var inputURL: URL
    var outputURL: URL?

    init(requestID: UUID = UUID(), inputURL: URL, outputURL: URL? = nil) {
        self.requestID = requestID
        self.inputURL = inputURL
        self.outputURL = outputURL
    }
}

typealias CleanOptions = CleaningOptions

enum FindingConfidence: String, Codable, CaseIterable, Comparable, Sendable {
    case confirmed
    case probable
    case informational
    case likelyFalsePositive = "likely_false_positive"

    private var sortOrder: Int {
        switch self {
        case .confirmed: 0
        case .probable: 1
        case .informational: 2
        case .likelyFalsePositive: 3
        }
    }

    static func < (lhs: FindingConfidence, rhs: FindingConfidence) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var displayName: String {
        switch self {
        case .confirmed: "Confirmed"
        case .probable: "Probable"
        case .informational: "Informational"
        case .likelyFalsePositive: "Likely false positive"
        }
    }

    var systemImage: String {
        switch self {
        case .confirmed: "checkmark.seal.fill"
        case .probable: "exclamationmark.triangle.fill"
        case .informational: "info.circle.fill"
        case .likelyFalsePositive: "questionmark.circle"
        }
    }
}

struct WatermarkFinding: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
    let confidence: FindingConfidence

    init(message: String, confidence: FindingConfidence, index: Int = 0) {
        self.id = "\(index):\(confidence.rawValue):\(message)"
        self.message = message
        self.confidence = confidence
    }
}

struct WatermarkReport: Equatable, Sendable {
    var raw: JSONValue

    init(raw: JSONValue = .object([:])) {
        self.raw = raw
    }

    var findings: [WatermarkFinding] {
        var result: [WatermarkFinding] = []
        let messages = strings(for: "findings")
        let confidences = strings(for: "findings_confidence")

        for (index, message) in messages.enumerated() {
            let confidence = confidences.indices.contains(index)
                ? FindingConfidence(rawValue: confidences[index]) ?? .informational
                : inferredConfidence(for: message)
            result.append(WatermarkFinding(message: message, confidence: confidence, index: index))
        }

        let hitValues = (raw["hits"]?.arrayValue ?? []) + (raw["layer_a_hits"]?.arrayValue ?? [])
        for (offset, hit) in hitValues.enumerated() {
            guard let object = hit.objectValue else { continue }
            let label = object["label"]?.stringValue
                ?? object["codepoint"]?.stringValue
                ?? "Invisible text carrier"
            let kind = object["kind"]?.stringValue
            let count = Int(object["count"]?.numberValue ?? 1)
            let message = [label, kind.map { "(\($0))" }, "×\(count)"]
                .compactMap { $0 }
                .joined(separator: " ")
            let confidence = object["confidence"]?.stringValue
                .flatMap(FindingConfidence.init(rawValue:)) ?? .probable
            result.append(
                WatermarkFinding(
                    message: message,
                    confidence: confidence,
                    index: messages.count + offset
                )
            )
        }

        return result.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.message < rhs.message }
            return lhs.confidence < rhs.confidence
        }
    }

    var actions: [String] {
        strings(for: "actions")
    }

    var notes: [String] {
        strings(for: "notes")
    }

    var postFindings: [String] {
        strings(for: "post_findings")
    }

    var hasActionableFindings: Bool {
        if raw["has_c2pa"]?.boolValue == true || raw["has_ai_metadata"]?.boolValue == true {
            return true
        }
        if (raw["suspicious_total"]?.numberValue ?? 0) > 0 {
            return true
        }
        return findings.contains { $0.confidence == .confirmed || $0.confidence == .probable }
    }

    var inspectionIncomplete: Bool {
        let diagnosticText = (notes + strings(for: "findings") + postFindings)
            .joined(separator: " ")
            .lowercased()
        let phrases = ["not fully inspected", "unavailable", "inconclusive", "unsupported", "skipped"]
        if phrases.contains(where: diagnosticText.contains) {
            return true
        }

        guard let tools = raw["tools"]?.objectValue else { return false }
        return tools.values.contains { value in
            value.objectValue?["available"]?.boolValue == false
        }
    }

    var didChange: Bool? {
        if let changed = raw["changed"]?.boolValue { return changed }
        guard let stats = raw["stats"]?.objectValue else { return nil }
        let removed = stats["removed_count"]?.numberValue ?? 0
        let replaced = stats["replaced_count"]?.numberValue ?? 0
        return removed + replaced > 0
    }

    var residualCount: Int {
        postFindings.count
    }

    private func strings(for key: String) -> [String] {
        raw[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func inferredConfidence(for message: String) -> FindingConfidence {
        let lowered = message.lowercased()
        if lowered.contains("c2pa") || lowered.contains("manifest") {
            return .confirmed
        }
        if lowered.contains("byte-scan") {
            return .likelyFalsePositive
        }
        if lowered.contains("not fully inspected") || lowered.contains("unsupported") {
            return .informational
        }
        return .probable
    }
}

struct EngineInspection: Equatable, Sendable {
    var kind: WatermarkKind
    var report: WatermarkReport
}

typealias InspectionResult = EngineInspection

struct EngineCleanResult: Equatable, Sendable {
    var kind: WatermarkKind
    var outputURL: URL
    var report: WatermarkReport
}

typealias CleanResult = EngineCleanResult

struct EngineCapabilities: Equatable, Sendable {
    var report: WatermarkReport
}
