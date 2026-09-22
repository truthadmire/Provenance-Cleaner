import SwiftUI

struct WordEditingTracesCard: View {
    let job: CleanerJob
    @Bindable var preferences: AppPreferences
    let optionsDisabled: Bool
    var onApply: () -> Void
    @State private var detailsExpanded = false
    @State private var changesExpanded = false

    private var inspection: WordTraceInspection? {
        job.inspection?.raw["word_editing_traces"].map(WordTraceInspection.init(raw:))
    }

    private var result: JSONValue? { job.cleanReport?.raw["word_trace_changes"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CleanerCardHeading(title: "Word editing traces", systemImage: "clock.arrow.circlepath")

            if let inspection, inspection.available {
                Text("\(inspection.count("sessionIDs")) session IDs · \(inspection.count("annotationDates")) revision/comment dates · \(inspection.count("documentDates")) document dates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("word-traces.inspection")

                VStack(alignment: .leading, spacing: 12) {
                    modePicker("Session identifiers", selection: $preferences.wordSessionMode, id: "word-traces.sessions")
                    modePicker("Recorded dates", selection: $preferences.wordDateMode, id: "word-traces.dates")
                    if preferences.wordDateMode == .randomize {
                        DatePicker("From", selection: $preferences.wordDateStart, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("word-traces.start")
                        DatePicker("To", selection: $preferences.wordDateEnd, displayedComponents: [.date, .hourAndMinute])
                            .accessibilityIdentifier("word-traces.end")
                        Text("Dates stay in chronological order. Equal timestamps stay equal. Range shown in your local time zone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !preferences.wordDateRangeValid {
                            Text("Choose an end after the start.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Toggle("Reset ZIP entry dates", isOn: $preferences.wordResetArchiveDates)
                        .accessibilityIdentifier("word-traces.archive-dates")
                }
                .disabled(optionsDisabled || inspection.signed)

                DisclosureGroup("What these fields reveal", isExpanded: $detailsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Session IDs group edits between saves; they do not contain exact typing times. Randomization keeps that grouping. Removal clears the session labels.")
                        Text("Recorded dates include document creation, modification and printing, and dates attached to revisions and comments. ZIP dates belong to internal files; resetting them uses 1 January 1980.")
                        if let earliest = inspection.earliest, let latest = inspection.latest {
                            Text("Recorded range: \(displayDate(earliest)) — \(displayDate(latest))")
                        }
                        if inspection.count("datesWithoutTimezone") > 0 {
                            Text("\(inspection.count("datesWithoutTimezone")) dates have no time zone and will be interpreted as UTC.")
                        }
                        if inspection.count("invalidDates") > 0 {
                            Text("\(inspection.count("invalidDates")) dates are empty or malformed. They can be kept or removed, but cannot be randomized.")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if inspection.signed {
                    Label("This document is digitally signed. Use an unsigned copy to edit its metadata.", systemImage: "signature")
                        .font(.caption)
                } else {
                    HStack {
                        Text("Applies to the original file’s metadata. Text, formatting, comments and tracked changes are preserved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 10)
                        Button("Apply editing traces", action: onApply)
                            .buttonStyle(.bordered)
                            .disabled(optionsDisabled || !job.status.canClean || !preferences.wordDateRangeValid || (preferences.wordDateMode == .randomize && inspection.count("invalidDates") > 0))
                            .accessibilityIdentifier("word-traces.apply")
                    }
                }
            } else {
                Text(inspection?.reason ?? "Inspect the document to see its editing metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let result {
                Divider().opacity(0.5)
                Text("Last result: \(Int(result["changedFields"]?.numberValue ?? 0)) metadata fields processed; \(Int(result["archiveDatesReset"]?.numberValue ?? 0)) ZIP dates reset.")
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("word-traces.result")
                if let after = result["after"] {
                    let summary = WordTraceInspection(raw: after)
                    Text("After: \(summary.count("sessionIDs")) session IDs · \(summary.count("annotationDates") + summary.count("documentDates")) recorded dates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Review metadata changes", isExpanded: $changesExpanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array((result["changes"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, change in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(change["part"]?.stringValue ?? "Document metadata")
                                        .fontWeight(.medium)
                                    Text("\(change["before"]?.stringValue ?? "Empty") → \(change["after"]?.stringValue ?? "Removed")")
                                        .textSelection(.enabled)
                                }
                            }
                            if result["changesTruncated"]?.boolValue == true {
                                Text("Showing the first 200 field changes. The totals include all processed fields.")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .cleanerSurface()
    }

    private func modePicker(_ title: String, selection: Binding<WordTraceMode>, id: String) -> some View {
        Picker(title, selection: selection) {
            ForEach(WordTraceMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .accessibilityIdentifier(id)
    }

    private func displayDate(_ value: String) -> String {
        ISO8601DateFormatter().date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
