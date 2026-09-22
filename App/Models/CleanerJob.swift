import Foundation

enum CleanerJobStatus: Equatable, Sendable {
    case queued
    case inspecting
    case inspectedClean
    case findings(Int)
    case inspectionIncomplete(Int)
    case cleaning
    case readyToExport(residualCount: Int)
    case editingTracesReady(residualCount: Int)
    case cleanedInspectionIncomplete
    case cancelled
    case exported(URL)
    case unsupported(String)
    case failed(String)

    var label: String {
        switch self {
        case .queued: "Queued"
        case .inspecting: "Inspecting…"
        case .inspectedClean: "No actionable findings"
        case let .findings(count): "\(count) finding\(count == 1 ? "" : "s")"
        case let .inspectionIncomplete(count):
            count > 0 ? "\(count) finding\(count == 1 ? "" : "s"); incomplete" : "Inspection incomplete"
        case .cleaning: "Cleaning…"
        case let .readyToExport(residualCount):
            residualCount > 0
                ? "Cleaned — residual risk (\(residualCount))"
                : "Cleaned — findings removed"
        case let .editingTracesReady(residualCount):
            residualCount > 0 ? "Metadata updated — other findings remain" : "Editing traces updated"
        case .cleanedInspectionIncomplete: "Cleaned — inspection incomplete"
        case .cancelled: "Cancelled"
        case let .exported(url): "Exported to \(url.lastPathComponent)"
        case .unsupported: "Unsupported"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .inspecting, .cleaning: "hourglass"
        case .inspectedClean: "checkmark.circle"
        case .findings: "exclamationmark.triangle"
        case .inspectionIncomplete, .cleanedInspectionIncomplete: "questionmark.circle"
        case .readyToExport, .editingTracesReady: "square.and.arrow.down"
        case .cancelled: "stop.circle"
        case .exported: "checkmark.seal"
        case .unsupported: "nosign"
        case .failed: "xmark.octagon"
        }
    }

    var canClean: Bool {
        switch self {
        case .inspectedClean, .findings, .inspectionIncomplete, .readyToExport, .editingTracesReady,
             .cleanedInspectionIncomplete, .cancelled, .exported:
            true
        default:
            false
        }
    }

    var isBusy: Bool {
        switch self {
        case .inspecting, .cleaning: true
        default: false
        }
    }
}

struct CleanerJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL
    var kind: WatermarkKind
    var status: CleanerJobStatus
    var inspection: WatermarkReport?
    var cleanReport: WatermarkReport?
    var postCleanInspection: WatermarkReport?
    var stagedOutputURL: URL?
    var cleaningOptions: CleaningOptions?

    init(id: UUID = UUID(), sourceURL: URL) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = .unknown
        self.status = .queued
    }

    var displayName: String {
        sourceURL.lastPathComponent
    }

    var previewURL: URL {
        stagedOutputURL ?? sourceURL
    }

    var canExport: Bool {
        stagedOutputURL != nil
    }
}

enum ExportChoice: String, Identifiable, Sendable {
    case copies
    case replaceOriginals

    var id: String { rawValue }
}
