import SwiftUI

/// What the original file contains. This tab always describes the original;
/// the Review tab describes the copy.
struct FindingsTabView: View {
    let job: CleanerJob
    var onInspect: () -> Void
    var onShowChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            if let report = job.inspection {
                if report.inspectionIncomplete {
                    IncompleteChecksCard(reasons: report.incompleteReasons)
                }

                VStack(alignment: .leading, spacing: Clay.space4) {
                    ClayCardHeader(
                        title: "What we found",
                        subtitle: job.replacement.map { "In the original file, now saved as \($0.backupURL.lastPathComponent)" }
                            ?? "In the original file"
                    )
                    if report.findings.isEmpty {
                        Text(report.inspectionIncomplete
                             ? "Nothing found by the checks that ran. Unchecked parts may still contain markers."
                             : "Nothing found by the available checks.")
                            .font(Clay.body)
                            .foregroundStyle(Clay.inkMuted)
                    } else {
                        FindingsList(findings: report.findings)
                    }
                }
                .clayCard()
                .accessibilityIdentifier("findings.card")

                if report.raw["c2pa"] != nil {
                    ContentCredentialsCard(report: report)
                }

                if job.isPDF, let traces = report.raw["pdf_traces"].map(PDFTraceInspection.init(raw:)), traces.hasContent {
                    PDFOriginCard(inspection: traces)
                }

                if job.isWordDocument, let traces = report.raw["word_editing_traces"] {
                    let inspection = WordTraceInspection(raw: traces)
                    if inspection.hasReviewMarkup {
                        WordReviewMarkupCard(inspection: inspection)
                    }
                    WordHistorySummaryCard(inspection: inspection, onShowChanges: onShowChanges)
                }

                VStack(alignment: .leading, spacing: Clay.space2) {
                    if !report.notes.isEmpty {
                        ClayDisclosure(title: "About these checks") {
                            VStack(alignment: .leading, spacing: Clay.space2) {
                                ForEach(report.notes, id: \.self) { note in
                                    Text(note)
                                        .font(Clay.caption)
                                        .foregroundStyle(Clay.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    TechnicalReportDisclosure(report: report)
                }

                Text("A report covers only the checks that ran. It doesn't prove that no watermark remains.")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            } else if job.status.isBusy {
                HStack(spacing: Clay.space3) {
                    ProgressView().controlSize(.small)
                    Text("Checking the original…")
                        .font(Clay.body)
                        .foregroundStyle(Clay.inkMuted)
                }
                .clayCard()
            } else {
                VStack(alignment: .leading, spacing: Clay.space3) {
                    ClayCardHeader(
                        title: "Not checked yet",
                        subtitle: "Checking is read-only and normally runs when you add a file."
                    )
                    if job.kind != .unknown {
                        Button("Check now", action: onInspect)
                            .buttonStyle(.claySecondary)
                    }
                }
                .clayCard()
            }
        }
    }
}

// MARK: - Shared rows

struct FindingsList: View {
    let findings: [WatermarkFinding]

    var body: some View {
        let groups = Dictionary(grouping: findings, by: \.category).sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: Clay.space4) {
            ForEach(groups, id: \.key) { category, items in
                VStack(alignment: .leading, spacing: Clay.space2) {
                    Text(category.title)
                        .font(Clay.captionMedium)
                        .foregroundStyle(Clay.inkMuted)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, finding in
                            if index > 0 {
                                Rectangle().fill(Clay.hairline).frame(height: 1)
                            }
                            FindingRow(finding: finding)
                        }
                    }
                }
            }
        }
    }
}

struct FindingRow: View {
    let finding: WatermarkFinding

    private var tone: ClayTone {
        finding.confidence <= .probable ? .warning : .neutral
    }

    var body: some View {
        HStack(alignment: .top, spacing: Clay.space3) {
            Circle()
                .fill(tone.foreground)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(finding.displayMessage)
                .font(Clay.body)
                .foregroundStyle(Clay.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ClayBadge(text: finding.confidence.displayName, tone: tone)
        }
        .padding(.vertical, Clay.space2)
        .accessibilityElement(children: .combine)
    }
}

struct IncompleteChecksCard: View {
    let reasons: [String]
    var title = "What couldn't be checked"

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(title: title) {
                ClayBadge(text: "Incomplete", tone: .warning)
            }
            VStack(alignment: .leading, spacing: Clay.space2) {
                ForEach(reasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: Clay.space3) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundStyle(Clay.warning)
                            .padding(.top, 3)
                        Text(reason)
                            .font(Clay.body)
                            .foregroundStyle(Clay.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Until these parts are checked, treat the result as incomplete.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
        }
        .clayCard()
        .accessibilityIdentifier("findings.incomplete")
    }
}

struct TechnicalReportDisclosure: View {
    let report: WatermarkReport

    var body: some View {
        ClayDisclosure(title: "Technical report (JSON)") {
            Text(report.raw.prettyPrinted)
                .font(Clay.code)
                .foregroundStyle(Clay.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Clay.space3)
                .background(Clay.sunken, in: RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous))
        }
    }
}

/// The software and dates a PDF names, and the generator traces in its structure.
private struct PDFOriginCard: View {
    let inspection: PDFTraceInspection

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(
                title: "How this PDF was made",
                subtitle: "Document properties and the naming some PDF libraries leave in the file's structure."
            ) {
                if !inspection.generators.isEmpty {
                    ClayBadge(text: "Tool traces", tone: .warning)
                }
            }
            if !inspection.properties.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: Clay.space6, verticalSpacing: Clay.space2) {
                    ForEach(inspection.properties, id: \.label) { property in
                        ClayKeyValueRow(
                            key: property.label,
                            value: ["Created", "Modified"].contains(property.label) ? ClayDate.display(property.value) : property.value
                        )
                    }
                }
            }
            ForEach(inspection.generators, id: \.name) { generator in
                HStack(alignment: .top, spacing: Clay.space3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Clay.warning)
                        .padding(.top, 3)
                    Text("Edited or made with \(generator.name): \(generator.evidence.joined(separator: "; ")).")
                        .font(Clay.body)
                        .foregroundStyle(Clay.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let reason = inspection.reason {
                Text(reason)
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
            Text("Removing provenance markers clears these properties, renames these traces and gives the copy a new document ID. Page text and links stay.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .clayCard()
        .accessibilityIdentifier("findings.pdfOrigin")
    }
}

/// Tracked changes and comments keep earlier text and reviewers' names in the
/// file, and no step of the copy removes them.
private struct WordReviewMarkupCard: View {
    let inspection: WordTraceInspection

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(
                title: "Tracked changes and comments",
                subtitle: "Anyone who opens this document can read them, including deleted text and who made each change. The copy keeps them too."
            ) {
                ClayBadge(text: "Still in the file", tone: .warning)
            }
            Grid(alignment: .leading, horizontalSpacing: Clay.space6, verticalSpacing: Clay.space2) {
                if inspection.trackedChanges > 0 {
                    ClayKeyValueRow(key: "Tracked changes", value: inspection.trackedChangeSummary)
                }
                if let authors = inspection.authors("changeAuthor") {
                    ClayKeyValueRow(key: "Changes by", value: authors)
                }
                if inspection.comments > 0 {
                    ClayKeyValueRow(key: "Comments", value: String(inspection.comments))
                }
                if let authors = inspection.authors("commentAuthor") {
                    ClayKeyValueRow(key: "Comments by", value: authors)
                }
            }
            Text("To remove them, accept or reject all changes and delete the comments in Word, then add the saved file again.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .clayCard()
        .accessibilityIdentifier("findings.wordReviewMarkup")
    }
}

private struct WordHistorySummaryCard: View {
    let inspection: WordTraceInspection
    var onShowChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            ClayCardHeader(
                title: "Word editing history",
                subtitle: "Session IDs and recorded dates show when and in how many sittings the document was edited."
            ) {
                Button("Change…", action: onShowChanges)
                    .buttonStyle(.clayGhost)
            }
            if inspection.available {
                Grid(alignment: .leading, horizontalSpacing: Clay.space6, verticalSpacing: Clay.space2) {
                    ClayKeyValueRow(key: "Session IDs", value: String(inspection.count("sessionIDs")))
                    ClayKeyValueRow(
                        key: "Recorded dates",
                        value: "\(inspection.count("annotationDates") + inspection.count("documentDates"))"
                    )
                    if let earliest = inspection.earliest, let latest = inspection.latest {
                        ClayKeyValueRow(key: "Date range", value: "\(ClayDate.display(earliest)) – \(ClayDate.display(latest))")
                    }
                }
                if inspection.signed {
                    Text("This document is digitally signed, so its editing history can't be changed.")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                }
            } else {
                Text(inspection.reason)
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
        }
        .clayCard()
    }
}

/// Dates from the engine arrive as ISO 8601 or OpenSSL-style strings.
enum ClayDate {
    static func display(_ value: String) -> String {
        date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    static func date(from value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let collapsed = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        return formatter.date(from: collapsed)
    }
}
