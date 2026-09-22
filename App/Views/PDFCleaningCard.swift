import SwiftUI

struct PDFCleaningCard: View {
    let job: CleanerJob
    @Bindable var preferences: AppPreferences
    let optionsDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CleanerCardHeading(title: "PDF cleaning", systemImage: "doc.richtext")
            Picker("Embedded images", selection: $preferences.deepImageMode) {
                ForEach(AppPreferences.DeepImageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .disabled(optionsDisabled)
            .accessibilityIdentifier("pdf.deep-image-mode")

            Text(preferences.deepImageMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let report = job.cleanReport {
                Divider().opacity(0.5)
                Label(resultSummary(report), systemImage: report.pdfDeepCleaningIncomplete ? "exclamationmark.triangle" : "doc.badge.checkmark")
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pdf.deep-image-result")
            }

            Text("PDF rewriting can change interactive features. Review the result before export.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .cleanerSurface()
    }

    private func resultSummary(_ report: WatermarkReport) -> String {
        if report.pdfDeepCleaningIncomplete {
            return "Deep cleaning did not complete. Embedded-image metadata may remain; see Cleaning actions."
        }
        let meta = report.raw["meta"]
        if meta?["images_reencoded"]?.boolValue == true {
            return "Embedded-image pass completed. Images were re-encoded to remove remaining metadata."
        }
        if meta?["deep_image_pass"]?.boolValue == true {
            return "Embedded-image pass completed without the additional lossy re-encoding step."
        }
        if meta?["deep_images"]?.stringValue == "never" {
            return "Document metadata cleaned. Embedded images were left untouched."
        }
        return "Document metadata cleaned. The automatic embedded-image pass was not needed."
    }
}
