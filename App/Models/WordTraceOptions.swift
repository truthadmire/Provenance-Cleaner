import Foundation

enum WordTraceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep, randomize, remove
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .keep: String(localized: "Keep")
        case .randomize: String(localized: "Randomize")
        case .remove: String(localized: "Remove")
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
    var reason: String { raw["reason"]?.stringValue.map(EngineText.localized) ?? String(localized: "Editing traces could not be inspected.") }
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
            count("insertions").nonZero.map { String(localized: "\($0) insertions") },
            count("deletions").nonZero.map { String(localized: "\($0) deletions") },
            count("moves").nonZero.map { String(localized: "\($0) moves") },
            count("formattingChanges").nonZero.map { String(localized: "\($0) formatting changes") },
        ].compactMap { $0 }
        if kinds.count == 1 { return kinds[0] }
        let list = kinds.joined(separator: AppLocale.listSeparator)
        return String(localized: "\(trackedChanges) (\(list))")
    }

    /// Author names as listed by the engine, noting any it left out of the list.
    func authors(_ key: String) -> String? {
        let names = raw[key + "s"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !names.isEmpty else { return nil }
        let more = count(key + "Count") - names.count
        let list = names.joined(separator: AppLocale.listSeparator)
        return more > 0 ? String(localized: "\(list) and \(more) more") : list
    }
}

private extension Int {
    var nonZero: Int? { self > 0 ? self : nil }
}
