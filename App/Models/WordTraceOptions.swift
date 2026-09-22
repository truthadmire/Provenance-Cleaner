import Foundation

enum WordTraceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, randomize, remove
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .keep: "Keep"
        case .randomize: "Randomize"
        case .remove: "Remove"
        }
    }
}

struct WordTraceOptions: Codable, Equatable, Sendable {
    var rsids: WordTraceMode = .randomize
    var dates: WordTraceMode = .keep
    var start: String = ""
    var end: String = ""
    var resetArchiveDates = false

    var summary: String {
        var result = "Word editing metadata only. Session IDs: \(rsids.displayName.lowercased()); dates: \(dates.displayName.lowercased())."
        if dates == .randomize {
            result += " Range: \(start) to \(end); chronological order preserved."
        }
        if resetArchiveDates { result += " ZIP entry timestamps reset to 1 January 1980." }
        return result
    }
}

struct WordTraceInspection {
    let raw: JSONValue
    var available: Bool { raw["available"]?.boolValue == true }
    var reason: String { raw["reason"]?.stringValue ?? "Editing traces could not be inspected." }
    var signed: Bool { raw["signed"]?.boolValue == true }
    func count(_ key: String) -> Int { Int(raw[key]?.numberValue ?? 0) }
    var earliest: String? { raw["earliest"]?.stringValue }
    var latest: String? { raw["latest"]?.stringValue }
}
