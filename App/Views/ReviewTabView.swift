import SwiftUI

/// The copy: what changed, what remains, and a side-by-side comparison.
struct ReviewTabView: View {
    @Bindable var store: AppStore
    let job: CleanerJob
    var onSaveCopy: () -> Void
    var onReplaceOriginal: () -> Void
    var onShowChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            if job.stagedOutputURL == nil {
                noCopyCard
                previewCard(title: "Preview", subtitle: "The original file")
            } else {
                if store.copyNeedsUpdate(job), !job.status.isBusy {
                    ClayBanner(
                        tone: .warning,
                        title: "This copy doesn't include your latest changes",
                        message: "Update the copy to apply them, or review the copy as it is."
                    ) {
                        Button("Update copy") {
                            Task { await store.createCopy(jobID: job.id) }
                        }
                        .buttonStyle(.claySecondary)
                        .disabled(!store.canCreateCopy(job) || store.isBusy)
                    }
                }
                ChangesAppliedCard(job: job)
                remainingCard
                if let report = job.postCleanInspection, report.raw["c2pa"] != nil {
                    ContentCredentialsCard(report: report, subtitle: "In your copy, checked offline")
                }
                if let replacement = job.replacement {
                    replacedCard(replacement)
                } else {
                    previewCard(title: "Compare", subtitle: "Original and your copy, side by side")
                    saveCard
                }
            }
        }
    }

    private var noCopyCard: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(
                title: "No copy yet",
                subtitle: "Choose what to change, then create a copy. You'll review it here before you save anything."
            )
            Button("Choose changes", action: onShowChanges)
                .buttonStyle(.claySecondary)
        }
        .clayCard()
    }

    @ViewBuilder
    private var remainingCard: some View {
        if let report = job.postCleanInspection {
            if report.inspectionIncomplete || job.cleanReport?.pdfDeepCleaningIncomplete == true {
                IncompleteChecksCard(
                    reasons: Self.mergedReasons(report, job.cleanReport),
                    title: "What couldn't be checked in the copy"
                )
            }
            VStack(alignment: .leading, spacing: Clay.space4) {
                ClayCardHeader(title: "Still in the copy")
                if report.actionableFindings.isEmpty {
                    if report.hasActionableFindings {
                        Label("The checks still flag provenance data, but gave no details. See the technical report.", systemImage: "exclamationmark.triangle")
                            .font(Clay.body)
                            .foregroundStyle(Clay.warning)
                    } else {
                        Label("The checks found nothing left to remove.", systemImage: "checkmark.circle")
                            .font(Clay.body)
                            .foregroundStyle(Clay.success)
                    }
                    let kept = report.findings.filter { $0.confidence > .probable }
                    if !kept.isEmpty {
                        Text("Kept on purpose, for your information:")
                            .font(Clay.caption)
                            .foregroundStyle(Clay.inkMuted)
                        FindingsList(findings: kept)
                    }
                } else {
                    FindingsList(findings: report.actionableFindings)
                    if !job.plan.removeProvenance {
                        Text("Removing provenance markers is turned off for this copy.")
                            .font(Clay.caption)
                            .foregroundStyle(Clay.inkMuted)
                    }
                }
                TechnicalReportDisclosure(report: report)
            }
            .clayCard()
            .accessibilityIdentifier("review.remaining")
        } else {
            ClayBanner(
                tone: .warning,
                title: "The copy couldn't be checked",
                message: "It was created, but checking it again failed. Review it carefully before you save."
            )
        }
    }

    private func previewCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            ClayCardHeader(title: title, subtitle: subtitle)
            FilePreviewView(job: job)
                .frame(height: 440)
        }
        .clayCard()
    }

    private var saveCard: some View {
        let outdated = store.copyNeedsUpdate(job)
        return VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(
                title: "Save",
                subtitle: "Save copy suggests the name \(SupportedFileTypes.cleanedFilename(for: job.sourceURL)). Replacing the original keeps the old version as \(job.displayName).bak, next to it."
            )
            if outdated {
                Label("Update the copy before saving it or replacing the original.", systemImage: "exclamationmark.triangle")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.warning)
            }
            HStack(spacing: Clay.space2) {
                Button(job.isSaved ? "Save again…" : "Save copy…", action: onSaveCopy)
                    .buttonStyle(.claySecondary)
                    .disabled(!store.canSaveCopy(job) || store.isBusy)
                    .accessibilityIdentifier("review.save")
                Button("Replace original…", action: onReplaceOriginal)
                    .buttonStyle(.clayDestructive)
                    .disabled(!store.canReplaceOriginal(job) || store.isBusy)
                    .accessibilityIdentifier("review.replace")
            }
            if !job.savedCopies.isEmpty {
                VStack(alignment: .leading, spacing: Clay.space1) {
                    ForEach(job.savedCopies, id: \.self) { url in
                        Button {
                            FilePanelService.reveal(url)
                        } label: {
                            Label("Saved as \(url.lastPathComponent)", systemImage: "checkmark")
                        }
                        .buttonStyle(ClayLinkButtonStyle())
                        .help(url.path)
                    }
                }
            }
        }
        .clayCard()
    }

    private func replacedCard(_ replacement: ReplacementResult) -> some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(
                title: "Original replaced",
                subtitle: "\(job.displayName) now contains this copy. The previous version is \(replacement.backupURL.lastPathComponent), next to it."
            )
            if replacement.removedDownloadSource {
                Text("The original's download-source record (Finder's \"Where from\") was not carried over. Tags, comments and permissions were kept.")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Checking and rebuilding are turned off for this file, because the file on disk is now the copy. To work from the previous version, add \(replacement.backupURL.lastPathComponent) after renaming it back.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show backup in Finder") {
                FilePanelService.reveal(replacement.backupURL)
            }
            .buttonStyle(.claySecondary)
        }
        .clayCard()
        .accessibilityIdentifier("review.replaced")
    }

    static func mergedReasons(_ reports: WatermarkReport?...) -> [String] {
        var reasons: [String] = []
        for reason in reports.compactMap({ $0 }).flatMap(\.incompleteReasons) where !reasons.contains(reason) {
            reasons.append(reason)
        }
        return reasons
    }
}

/// Per-step results and the properties that differ between original and copy.
private struct ChangesAppliedCard: View {
    let job: CleanerJob

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            ClayCardHeader(title: "What changed")

            ForEach(Array(job.buildSteps.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: Clay.space2) {
                    Text(step.kind.title)
                        .font(Clay.captionMedium)
                        .foregroundStyle(Clay.inkMuted)
                    let actions = step.report.changeDescriptions
                    if actions.isEmpty {
                        Text(step.report.didChange == false ? "Nothing needed changing." : "Done. The engine gave no details.")
                            .font(Clay.body)
                            .foregroundStyle(Clay.inkMuted)
                    } else {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            HStack(alignment: .top, spacing: Clay.space2) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Clay.success)
                                    .padding(.top, 4)
                                Text(action)
                                    .font(Clay.body)
                                    .foregroundStyle(Clay.ink)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if step.kind == .provenance, job.isPDF {
                        Text(pdfSummary(step.report))
                            .font(Clay.caption)
                            .foregroundStyle(step.report.pdfDeepCleaningIncomplete ? Clay.warning : Clay.inkMuted)
                            .accessibilityIdentifier("pdf.deep-image-result")
                    }
                    if step.kind == .wordTraces, let result = step.report.raw["word_trace_changes"] {
                        WordTraceChangesDisclosure(result: result)
                    }
                }
            }

            if !propertyChanges.isEmpty {
                Rectangle().fill(Clay.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: Clay.space2) {
                    Text("Properties: original → copy")
                        .font(Clay.captionMedium)
                        .foregroundStyle(Clay.inkMuted)
                    Grid(alignment: .leading, horizontalSpacing: Clay.space4, verticalSpacing: Clay.space2) {
                        ForEach(propertyChanges, id: \.label) { change in
                            GridRow(alignment: .firstTextBaseline) {
                                Text(change.label)
                                    .font(Clay.caption)
                                    .foregroundStyle(Clay.inkMuted)
                                Text(change.before.isEmpty ? "Not set" : change.before)
                                    .font(Clay.body)
                                    .foregroundStyle(Clay.inkMuted)
                                    .strikethrough(!change.before.isEmpty, color: Clay.inkMuted)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Clay.inkMuted)
                                Text(change.after.isEmpty ? "Removed" : change.after)
                                    .font(Clay.bodyMedium)
                                    .foregroundStyle(Clay.ink)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("review.properties")
            }
        }
        .clayCard()
        .accessibilityIdentifier("review.changes")
    }

    private var propertyChanges: [(label: String, before: String, after: String)] {
        let before = Self.fieldValues(job.inspection)
        let after = Self.fieldValues(job.postCleanInspection)
        guard !after.isEmpty else { return [] }
        return before.compactMap { field in
            guard let afterValue = after.first(where: { $0.id == field.id })?.value,
                  afterValue != field.value else { return nil }
            return (field.label, field.value, afterValue)
        }
    }

    private static func fieldValues(_ report: WatermarkReport?) -> [(id: String, label: String, value: String)] {
        (report?.raw["metadata"]?["fields"]?.arrayValue ?? []).compactMap { field in
            guard let id = field["id"]?.stringValue, let label = field["label"]?.stringValue else { return nil }
            return (id, label, field["value"]?.stringValue ?? "")
        }
    }

    private func pdfSummary(_ report: WatermarkReport) -> String {
        if report.pdfDeepCleaningIncomplete {
            return "The embedded-image pass didn't finish. Image metadata may remain."
        }
        let meta = report.raw["meta"]
        if meta?["images_reencoded"]?.boolValue == true {
            return "Embedded images were re-encoded to remove remaining metadata."
        }
        if meta?["deep_image_pass"]?.boolValue == true {
            return "Embedded images were cleaned without lossy re-encoding."
        }
        if meta?["deep_images"]?.stringValue == "never" {
            return "Embedded images were left untouched."
        }
        return "Embedded images didn't need cleaning."
    }
}

private struct WordTraceChangesDisclosure: View {
    let result: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space2) {
            Text("\(Int(result["changedFields"]?.numberValue ?? 0)) editing-history fields changed; \(Int(result["archiveDatesReset"]?.numberValue ?? 0)) ZIP dates reset.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .accessibilityIdentifier("word-traces.result")
            ClayDisclosure(title: "Show each change") {
                VStack(alignment: .leading, spacing: Clay.space2) {
                    ForEach(Array((result["changes"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change["part"]?.stringValue ?? "Document metadata")
                                .font(Clay.code)
                                .foregroundStyle(Clay.inkMuted)
                            Text("\(change["before"]?.stringValue ?? "Empty") → \(change["after"]?.stringValue ?? "Removed")")
                                .font(Clay.caption)
                                .foregroundStyle(Clay.ink)
                                .textSelection(.enabled)
                        }
                    }
                    if result["changesTruncated"]?.boolValue == true {
                        Text("Showing the first 200 changes. The totals above include every field.")
                            .font(Clay.caption)
                            .foregroundStyle(Clay.inkMuted)
                    }
                }
            }
        }
    }
}
