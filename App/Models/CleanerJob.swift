import Foundation

enum CleanerJobStatus: Equatable, Sendable {
    case queued
    case inspecting
    case inspectedClean
    case findings(Int)
    case inspectionIncomplete(Int)
    case cleaning
    case readyToExport(residualCount: Int)
    case cleanedInspectionIncomplete
    case cancelled
    case unsupported(String)
    case failed(String)

    /// Short label for the queue sidebar.
    var label: String {
        switch self {
        case .queued: "Waiting"
        case .inspecting: "Checking…"
        case .inspectedClean: "Nothing found"
        case let .findings(count): "\(count) finding\(count == 1 ? "" : "s")"
        case let .inspectionIncomplete(count):
            count > 0 ? "\(count) finding\(count == 1 ? "" : "s") · check incomplete" : "Check incomplete"
        case .cleaning: "Creating copy…"
        case let .readyToExport(residualCount):
            residualCount > 0 ? "Copy ready · \(residualCount) remain\(residualCount == 1 ? "s" : "")" : "Copy ready"
        case .cleanedInspectionIncomplete: "Copy ready · check incomplete"
        case .cancelled: "Stopped"
        case .unsupported: "Not supported"
        case .failed: "Failed"
        }
    }

    var tone: ClayTone {
        switch self {
        case .queued, .cancelled, .unsupported: .neutral
        case .inspecting, .cleaning: .progress
        case .inspectedClean: .success
        case let .readyToExport(residualCount): residualCount > 0 ? .warning : .success
        case .findings, .inspectionIncomplete, .cleanedInspectionIncomplete: .warning
        case .failed: .danger
        }
    }

    /// Whether a copy can be created (or recreated) from the original.
    var canClean: Bool {
        switch self {
        case .inspectedClean, .findings, .inspectionIncomplete, .readyToExport,
             .cleanedInspectionIncomplete, .cancelled, .failed:
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

/// What the next copy of a file will contain. Every copy is built from the
/// original, in a fixed order, so no choice can silently undo another.
struct JobPlan: Equatable, Sendable {
    var removeProvenance = true
    var changeWordTraces = false
    /// Desired values for the descriptive properties the user changed. An
    /// empty string removes that property.
    var propertyEdits: [String: String] = [:]

    var isEmpty: Bool {
        !removeProvenance && !changeWordTraces && propertyEdits.isEmpty
    }

    static func propertyValueIsValid(_ value: String) -> Bool {
        value.unicodeScalars.count <= 4096
            && !value.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" }
    }

    var propertyEditsAreValid: Bool {
        propertyEdits.values.allSatisfy(Self.propertyValueIsValid)
    }
}

/// One engine operation in the build of a copy, in execution order.
enum BuildStepKind: String, CaseIterable, Equatable, Sendable {
    case provenance
    case wordTraces
    case properties
    case checking

    var title: String {
        switch self {
        case .provenance: "Remove provenance markers"
        case .wordTraces: "Change Word editing history"
        case .properties: "Update document properties"
        case .checking: "Check the copy"
        }
    }

    var progressTitle: String {
        switch self {
        case .provenance: "Removing provenance markers…"
        case .wordTraces: "Changing Word editing history…"
        case .properties: "Updating document properties…"
        case .checking: "Checking the copy…"
        }
    }
}

struct BuildStepResult: Equatable, Sendable {
    let kind: BuildStepKind
    let options: CleaningOptions
    let report: WatermarkReport
}

struct CleanerJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceURL: URL
    var kind: WatermarkKind
    var status: CleanerJobStatus
    var plan = JobPlan()
    /// Inspection of the original file.
    var inspection: WatermarkReport?
    /// Report of the provenance-cleaning step of the current copy, if it ran.
    var cleanReport: WatermarkReport?
    /// Inspection of the current copy.
    var postCleanInspection: WatermarkReport?
    var stagedOutputURL: URL?
    /// Provenance-cleaning options used for the current copy, if that step ran.
    var cleaningOptions: CleaningOptions?
    /// The plan and per-step reports that produced the current copy.
    var appliedPlan: JobPlan?
    var buildSteps: [BuildStepResult] = []
    var activeStep: BuildStepKind?
    /// Increments each time a new copy replaces the previous one.
    var resultRevision = 0
    /// Where the current copy has been saved. Kept apart from `status` so a
    /// re-check or a failure never erases it, and it never hides a warning.
    var savedCopies: [URL] = []
    /// Set once the original has been replaced by a copy. From then on the
    /// file at `sourceURL` is the cleaned copy, not the original.
    var replacement: ReplacementResult?
    /// The original as it was when it was last inspected.
    var inspectedFingerprint: FileFingerprint?
    /// The original as it was when the current copy was built from it.
    var copySourceFingerprint: FileFingerprint?

    init(id: UUID = UUID(), sourceURL: URL) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = .unknown
        self.status = .queued
    }

    var displayName: String {
        sourceURL.lastPathComponent
    }

    var fileExtension: String {
        sourceURL.pathExtension.lowercased()
    }

    var isWordDocument: Bool { fileExtension == "docx" }
    var isOfficeDocument: Bool { ["docx", "xlsx", "pptx"].contains(fileExtension) }
    var isPDF: Bool { fileExtension == "pdf" }

    var previewURL: URL {
        stagedOutputURL ?? sourceURL
    }

    /// Never present an original's validation as the staged result's verdict.
    var currentInspection: WatermarkReport? {
        stagedOutputURL == nil ? inspection : postCleanInspection
    }

    var canExport: Bool {
        stagedOutputURL != nil
    }

    var isReplaced: Bool { replacement != nil }
    var isSaved: Bool { !savedCopies.isEmpty }

    /// Short label for the queue sidebar, including save state.
    var queueLabel: String {
        if isReplaced { return "Original replaced" }
        guard isSaved, !status.isBusy else { return status.label }
        switch status {
        case let .readyToExport(remaining) where remaining > 0:
            return "Saved · \(remaining) remain\(remaining == 1 ? "s" : "")"
        case .cleanedInspectionIncomplete:
            return "Saved · check incomplete"
        case .readyToExport:
            return "Saved"
        default:
            return status.label
        }
    }

    /// The current copy no longer matches the choices on the Changes tab.
    var copyIsOutdated: Bool {
        guard stagedOutputURL != nil, let appliedPlan else { return false }
        return appliedPlan != plan
    }

    func stepResult(_ kind: BuildStepKind) -> BuildStepResult? {
        buildSteps.first { $0.kind == kind }
    }
}

enum ExportChoice: String, Identifiable, Sendable {
    case copies
    case replaceOriginals

    var id: String { rawValue }
}
