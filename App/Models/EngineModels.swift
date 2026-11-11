import Foundation

enum WatermarkKind: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case container
    case av
    case unknown

    var displayName: String {
        switch self {
        case .text: String(localized: "Text")
        case .image: String(localized: "Image")
        case .container: String(localized: "Document")
        case .av: String(localized: "Audio or video")
        case .unknown: String(localized: "Unknown")
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
    var wordTraces: WordTraceOptions? = nil
    var metadataEdits: [String: String]? = nil

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
        case .confirmed: String(localized: "Confirmed")
        case .probable: String(localized: "Probable")
        case .informational: String(localized: "Informational")
        case .likelyFalsePositive: String(localized: "Likely false positive")
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

enum FindingCategory: String, CaseIterable, Comparable, Sendable {
    case credentials
    case metadata
    case invisibleText
    case other

    var title: String {
        switch self {
        case .credentials: String(localized: "Content credentials")
        case .metadata: String(localized: "Metadata")
        case .invisibleText: String(localized: "Invisible characters")
        case .other: String(localized: "Other signals")
        }
    }

    static func < (lhs: FindingCategory, rhs: FindingCategory) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Groups engine messages by what they are about. Keyword-based, so an
    /// unrecognised message lands in String(localized: "Other signals") rather than being hidden.
    static func classify(_ message: String) -> FindingCategory {
        let lowered = message.lowercased()
        if ["c2pa", "jumbf", "manifest", "credential"].contains(where: lowered.contains) {
            return .credentials
        }
        if ["u+", "zero width", "invisible", "layer-a", "layer a", "bidi", "variation selector", "codepoint"]
            .contains(where: lowered.contains) {
            return .invisibleText
        }
        if ["metadata", "xmp", "exif", "iptc", "frontmatter", "generator", "software", "docprops", "creator",
            "author", "comment", "text chunk", "itxt", "description", "producer", "digitalsourcetype"]
            .contains(where: lowered.contains) {
            return .metadata
        }
        return .other
    }
}

struct WatermarkFinding: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
    let confidence: FindingConfidence
    let category: FindingCategory

    init(message: String, confidence: FindingConfidence, index: Int = 0, category: FindingCategory? = nil) {
        self.id = "\(index):\(confidence.rawValue):\(message)"
        self.message = message
        self.confidence = confidence
        self.category = category ?? FindingCategory.classify(message)
    }

    /// The engine message with repeated list items removed, e.g.
    /// "APP11: c2pa, C2PA, jumb, JUMB" becomes "APP11: c2pa, jumb".
    var displayMessage: String {
        guard let colon = message.range(of: ": ", options: .backwards) else { return message }
        let items = message[colon.upperBound...].components(separatedBy: ", ")
        guard items.count > 1 else { return message }
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.lowercased()).inserted }
        guard unique.count < items.count else { return message }
        return message[..<colon.upperBound] + unique.joined(separator: ", ")
    }

    /// `displayMessage` in the app's language, where the engine's wording is translated.
    var localizedDisplayMessage: String { EngineText.localized(displayMessage) }
}

/// What an offline credential check established. The app's logic reads this,
/// never the wording shown for it.
enum CredentialStatus: Sendable {
    case validationFailed, unableToVerify, detected, markersDetected, noCredentials, notInspected

    var title: String {
        switch self {
        case .validationFailed: String(localized: "Validation failed")
        case .unableToVerify: String(localized: "Unable to verify")
        case .detected: String(localized: "Credentials detected")
        case .markersDetected: String(localized: "Markers detected")
        case .noCredentials: String(localized: "No credentials found")
        case .notInspected: String(localized: "Not inspected")
        }
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
                    index: messages.count + offset,
                    category: .invisibleText
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
        let findings = findings
        if findings.contains(where: { $0.confidence <= .probable }) {
            return true
        }
        // The raw total also counts informational hits such as typographic
        // spaces kept on purpose, so it only decides when nothing is itemised.
        return findings.isEmpty && (raw["suspicious_total"]?.numberValue ?? 0) > 0
    }

    /// Readable change lines: the engine's actions, or its text statistics
    /// when a text clean reports counts instead of actions.
    var changeDescriptions: [String] {
        if !actions.isEmpty { return actions.map(EngineText.localized) }
        guard let stats = raw["stats"]?.objectValue else { return [] }
        var lines: [String] = []
        for (label, count) in (stats["removed"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append(String(localized: "Removed \(label) ×\(Int(count.numberValue ?? 0))"))
        }
        for (label, count) in (stats["replaced"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            lines.append(String(localized: "Replaced \(label) ×\(Int(count.numberValue ?? 0))"))
        }
        return lines
    }

    var inspectionIncomplete: Bool {
        if pdfDeepCleaningIncomplete || raw["c2pa"]?["inspectionIncomplete"]?.boolValue == true || raw["metadata"]?["incomplete"]?.boolValue == true { return true }
        let diagnosticText = (notes + strings(for: "findings") + postFindings)
            .joined(separator: " ")
            .lowercased()
        let phrases = ["not fully inspected", "unavailable", "inconclusive", "unsupported", "skipped"]
        if phrases.contains(where: diagnosticText.contains) {
            return true
        }

        guard let tools = raw["tools"]?.objectValue else { return false }
        return tools.values.contains { value in
            value.objectValue?["available"]?.boolValue == false || value.objectValue?["error"]?.stringValue != nil
        }
    }

    /// Confirmed or probable findings: the ones a copy should remove.
    var actionableFindings: [WatermarkFinding] {
        findings.filter { $0.confidence <= .probable }
    }

    /// Plain explanations of what could not be checked. Never empty when
    /// `inspectionIncomplete` is true, so an incomplete verdict always says why.
    var incompleteReasons: [String] {
        var reasons: [String] = []
        func add(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  !reasons.contains(text) else { return }
            reasons.append(text)
        }
        func toolMessage(_ error: String) -> String {
            var text = error
            if text.lowercased().hasPrefix("error: ") { text.removeFirst(7) }
            return text.prefix(1).lowercased() + text.dropFirst()
        }

        let c2pa = raw["c2pa"]
        if pdfDeepCleaningIncomplete {
            add(String(localized: "The embedded-image pass for this PDF didn't finish, so image metadata may remain."))
        }
        if let error = c2pa?["error"]?.stringValue {
            add(String(localized: "Content credentials couldn't be read: \(toolMessage(error))."))
        }
        if c2pa?["document"]?["inspectionIncomplete"]?.boolValue == true {
            let error = c2pa?["document"]?["error"]?.stringValue.map(toolMessage) ?? String(localized: "verification didn't complete")
            add(String(localized: "The document's own credential couldn't be checked: \(error)."))
        }
        for asset in c2pa?["embeddedAssets"]?.arrayValue ?? [] where asset["inspectionIncomplete"]?.boolValue == true {
            let path = asset["path"]?.stringValue ?? String(localized: "An embedded file")
            let error = asset["error"]?.stringValue.map(toolMessage) ?? String(localized: "verification didn't complete")
            add(String(localized: "\(path) couldn't be checked for content credentials (\(error))."))
        }
        for error in c2pa?["coverageErrors"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            add(EngineText.localized(error))
        }
        if let error = c2pa?["certificateError"]?.stringValue {
            add(String(localized: "The signing certificates couldn't be read: \(toolMessage(error))."))
        }
        if raw["metadata"]?["incomplete"]?.boolValue == true {
            add(raw["metadata"]?["note"]?.stringValue.map(EngineText.localized) ?? String(localized: "Some metadata couldn't be read."))
        }
        for (name, value) in (raw["tools"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            if value.objectValue?["available"]?.boolValue == false {
                add(String(localized: "\(name) isn't available, so its checks didn't run."))
            } else if let error = value.objectValue?["error"]?.stringValue {
                add(String(localized: "\(name): \(toolMessage(error))"))
            }
        }
        let phrases = ["not fully inspected", "unavailable", "inconclusive", "unsupported", "skipped"]
        for text in notes + strings(for: "findings") + postFindings
        where phrases.contains(where: text.lowercased().contains) {
            add(EngineText.localized(text))
        }
        if reasons.isEmpty, inspectionIncomplete {
            add(String(localized: "Some checks couldn't run on this file."))
        }
        return reasons
    }

    var credentialNeedsAttention: Bool {
        raw["c2pa"]?["inspectionIncomplete"]?.boolValue == true || raw["c2pa"]?["validationFailed"]?.boolValue == true
    }

    var credentialStatus: CredentialStatus {
        Self.credentialStatus(for: raw["c2pa"], markersDetected: raw["has_c2pa"]?.boolValue == true)
    }

    var credentialSummary: String { credentialStatus.title }

    static func credentialSummary(for value: JSONValue?, markersDetected: Bool = false) -> String {
        credentialStatus(for: value, markersDetected: markersDetected).title
    }

    static func credentialStatus(for value: JSONValue?, markersDetected: Bool = false) -> CredentialStatus {
        if value?["validationFailed"]?.boolValue == true { return .validationFailed }
        if value?["inspectionIncomplete"]?.boolValue == true { return .unableToVerify }
        switch value?["state"]?.stringValue {
        case "present": return .detected
        case "absent": return markersDetected ? .markersDetected : .noCredentials
        case nil: return .notInspected
        default: return .unableToVerify
        }
    }

    var pdfDeepCleaningIncomplete: Bool {
        raw["pdf_deep_clean_incomplete"]?.boolValue == true
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
        if lowered.contains("unavailable") || lowered.contains("inconclusive") || lowered.contains("not fully inspected") || lowered.contains("unsupported") {
            return .informational
        }
        if lowered.contains("byte-scan") {
            return .likelyFalsePositive
        }
        if lowered.contains("c2pa") || lowered.contains("manifest") {
            return .probable
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

    var supportsPDFDeepCleaning: Bool {
        report.raw["upstream"]?["tools"]?["ghostscript"]?.boolValue == true
    }
}
