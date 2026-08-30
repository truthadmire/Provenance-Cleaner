import SwiftUI

enum JobDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case preview = "Preview"

    var id: String { rawValue }
}

struct JobDetailView: View {
    let job: CleanerJob
    @Bindable var preferences: AppPreferences
    let isBatchBusy: Bool
    @Binding var selectedTab: JobDetailTab
    var onInspect: () -> Void
    var onClean: () -> Void
    var onExportCopy: () -> Void
    var onReplaceOriginal: () -> Void
    var onReveal: () -> Void

    @State private var showingReplaceConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("View", selection: $selectedTab) {
                ForEach(JobDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .padding(.top, 14)
            .accessibilityIdentifier("detail.view-picker")

            switch selectedTab {
            case .overview:
                JobOverviewView(
                    job: job,
                    preferences: preferences,
                    optionsDisabled: job.status.isBusy || isBatchBusy
                )
            case .preview:
                FilePreviewView(job: job)
            }
        }
        .confirmationDialog(
            "Replace \(job.displayName)?",
            isPresented: $showingReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace and Keep .bak", role: .destructive, action: onReplaceOriginal)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original is copied to \(job.displayName).bak first. An existing backup is never overwritten.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: job.kind.systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Button(action: onReveal) {
                    Text(job.sourceURL.deletingLastPathComponent().path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder")
            }

            Spacer()

            StatusBadge(status: job.status)
                .accessibilityIdentifier("detail.status")

            Button("Inspect", action: onInspect)
                .disabled(job.status.isBusy || isBatchBusy)
                .accessibilityIdentifier("detail.inspect")

            Button("Clean", action: onClean)
                .buttonStyle(.borderedProminent)
                .disabled(!job.status.canClean || job.status.isBusy || isBatchBusy)
                .accessibilityIdentifier("detail.clean")

            if job.canExport {
                Menu {
                    Button("Save Cleaned Copy…", action: onExportCopy)
                    Button("Replace Original and Keep .bak", role: .destructive) {
                        showingReplaceConfirmation = true
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .menuIndicator(.visible)
                .accessibilityIdentifier("detail.export")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct StatusBadge: View {
    let status: CleanerJobStatus

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}

private struct JobOverviewView: View {
    let job: CleanerJob
    @Bindable var preferences: AppPreferences
    let optionsDisabled: Bool
    @State private var rawReportExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CurrentCleaningOptionsCard(preferences: preferences)
                    .disabled(optionsDisabled)

                if job.sourceURL.pathExtension.lowercased() == "pdf" {
                    NoticeCard(
                        title: "PDF embedded-image limitation",
                        message: "Ghostscript is not bundled. ExifTool and qpdf handle document-level metadata and structural rewrites, but provenance metadata inside some embedded PDF images may remain. Review the result before export.",
                        systemImage: "exclamationmark.shield"
                    )
                }

                if let options = job.cleaningOptions {
                    NoticeCard(
                        title: "Options used for this result",
                        message: options.summary,
                        systemImage: "slider.horizontal.3"
                    )
                }

                if let error = job.status.errorMessage {
                    NoticeCard(
                        title: "This item needs attention",
                        message: error,
                        systemImage: "exclamationmark.octagon.fill"
                    )
                }

                if let report = job.inspection {
                    ReportCard(title: "Inspection", report: report)
                } else if !job.status.isBusy {
                    NoticeCard(
                        title: "Not inspected yet",
                        message: "Inspection is read-only and runs automatically when a supported file is added.",
                        systemImage: "magnifyingglass"
                    )
                }

                if let cleanReport = job.cleanReport {
                    CleanActionsCard(report: cleanReport)
                }

                if job.stagedOutputURL != nil {
                    if let after = job.postCleanInspection {
                        ReportCard(title: "Post-clean inspection", report: after)
                    } else {
                        NoticeCard(
                            title: "Post-clean inspection unavailable",
                            message: "A cleaned output was created, but it could not be inspected again. Review the output before export.",
                            systemImage: "questionmark.circle"
                        )
                    }
                }

                DisclosureGroup("Raw engine report", isExpanded: $rawReportExpanded) {
                    Text((job.postCleanInspection ?? job.cleanReport ?? job.inspection)?.raw.prettyPrinted ?? "{}")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

                Text("A clean report describes only the checks that ran. It is not a universal certificate that no watermark remains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct CurrentCleaningOptionsCard: View {
    @Bindable var preferences: AppPreferences
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Options for the next clean")
                    .font(.headline)
                Spacer()
                SettingsLink {
                    Text("All Settings")
                }
                .font(.caption)
            }

            Toggle("Preserve unrelated metadata", isOn: $preferences.keepNonAIMetadata)
            Text("Keep ordinary author, date, camera, and document metadata while removing recognized provenance fields.")
                .font(.caption)
                .foregroundStyle(.secondary)

            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Normalize unusual spaces", isOn: $preferences.normalizeSpaces)
                    Text("Off by default because non-breaking and narrow spaces can be meaningful typography.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
}

private struct ReportCard: View {
    let title: String
    let report: WatermarkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if report.inspectionIncomplete {
                    Label("Incomplete", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if report.hasActionableFindings {
                    Label("Actionable findings", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                } else {
                    Label("No actionable findings", systemImage: "checkmark.circle")
                        .font(.caption)
                }
            }

            if report.findings.isEmpty {
                Text("No confirmed or probable provenance marks were reported by the available checks.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.findings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: finding.confidence.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.message)
                                .textSelection(.enabled)
                            Text(finding.confidence.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            ForEach(report.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
}

private struct CleanActionsCard: View {
    let report: WatermarkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleaning actions")
                .font(.headline)

            if report.actions.isEmpty {
                Text(report.didChange == false ? "The output matched the input." : "The engine returned no action details.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.actions, id: \.self) { action in
                    Label(action, systemImage: "checkmark")
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }
}

private struct NoticeCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension CleanerJobStatus {
    var errorMessage: String? {
        switch self {
        case let .unsupported(message), let .failed(message): message
        default: nil
        }
    }
}

private extension CleaningOptions {
    var summary: String {
        let metadata = stripAllMetadata
            ? "all removable metadata requested"
            : "unrelated metadata preserved"
        let spaces = normalizeSpaces ? "spaces normalized" : "typography preserved"
        return "\(metadata.capitalized); \(spaces); PDF deep-image mode: \(deepImages)."
    }
}
