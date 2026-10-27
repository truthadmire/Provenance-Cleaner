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

    var trackedChanges: Int {
        ["insertions", "deletions", "moves", "formattingChanges"].reduce(0) { $0 + count($1) }
    }
    var comments: Int { count("comments") }
    var hasReviewMarkup: Bool { available && trackedChanges + comments > 0 }

    /// "3 (1 insertion, 2 deletions)", leaving out kinds that don't occur.
    var trackedChangeSummary: String {
        let kinds = [
            ("insertions", "insertion", "insertions"), ("deletions", "deletion", "deletions"),
            ("moves", "move", "moves"), ("formattingChanges", "formatting change", "formatting changes"),
        ]
            .compactMap { key, one, many in
                let n = count(key)
                return n > 0 ? "\(n) \(n == 1 ? one : many)" : nil
            }
        return kinds.count == 1 ? kinds[0] : "\(trackedChanges) (\(kinds.joined(separator: ", ")))"
    }

    /// Author names as listed by the engine, noting any it left out of the list.
    func authors(_ key: String) -> String? {
        let names = raw[key + "s"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !names.isEmpty else { return nil }
        let more = count(key + "Count") - names.count
        return names.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
    }
}
