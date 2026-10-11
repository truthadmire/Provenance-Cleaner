import SwiftUI

struct InspectionSummaryView: View {
    let job: CleanerJob
    private var report: WatermarkReport? { job.currentInspection }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            metric("FINDINGS", value: report.map { String($0.findings.filter { $0.confidence <= .probable }.count) } ?? "—", detail: "Confirmed or probable", color: report?.hasActionableFindings == true ? .orange : .primary)
            Divider().frame(height: 66).padding(.horizontal, 20)
            metric("CONTENT CREDENTIALS", value: credentialLabel, detail: "C2PA inspection", color: .primary)
            Divider().frame(height: 66).padding(.horizontal, 20)
            metric("WORKING COPY", value: job.stagedOutputURL == nil ? "Original" : "Updated", detail: job.stagedOutputURL == nil ? "Read-only inspection" : "Ready for review", color: .primary)
        }
        .padding(24).cleanerSurface()
    }

    private var credentialLabel: String {
        switch report?.raw["c2pa"]?["state"]?.stringValue {
        case "present": "Detected"
        case "absent": report?.raw["has_c2pa"]?.boolValue == true ? "Markers only" : "None found"
        case "not_applicable": "Not applicable"
        case nil: "—"
        default: "Unresolved"
        }
    }

    private func metric(_ title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold)).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
