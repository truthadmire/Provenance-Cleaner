import Foundation

/// The engine's `pdf_traces` report: document properties that name the
/// software and dates, plus structural traces left by known PDF generators.
struct PDFTraceInspection {
    struct Property: Equatable {
        let label: String
        let value: String
    }

    struct Generator: Equatable {
        let name: String
        let evidence: [String]
    }

    let raw: JSONValue

    var available: Bool { raw["available"]?.boolValue == true }
    var reason: String? { raw["reason"]?.stringValue }

    var properties: [Property] {
        (raw["properties"]?.arrayValue ?? []).compactMap { item in
            guard let label = item["label"]?.stringValue, let value = item["value"]?.stringValue else { return nil }
            return Property(label: label, value: value)
        }
    }

    var generators: [Generator] {
        (raw["generators"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            return Generator(name: name, evidence: item["evidence"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
    }

    var hasContent: Bool { !properties.isEmpty || !generators.isEmpty || reason != nil }
}
