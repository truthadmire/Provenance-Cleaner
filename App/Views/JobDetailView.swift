import SwiftUI

enum JobDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case metadata = "Metadata"
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
    var onEditWordTraces: () -> Void
    var onEditMetadata: ([String: String]) -> Void
    var onExportCopy: () -> Void
    var onReplaceOriginal: () -> Void
    var onReveal: () -> Void

    @State private var showingReplaceConfirmation = false
    @State private var metadataDraft: [String: String] = [:]

    var body: some View {
        // The header owns its layout space. An inset on the scroll view lets
        // scrolled content draw into that inset, behind the header and tabs.
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header

                HStack(spacing: 24) {
                    ForEach(JobDetailTab.allCases) { tab in
                        Button { selectedTab = tab } label: {
                            VStack(spacing: 12) {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                                    .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                                Capsule().fill(selectedTab == tab ? Color.accentColor : .clear).frame(height: 2)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("detail.tab.\(tab.rawValue.lowercased())")
                    }
                    Spacer()
                    Label("On-device", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .frame(maxWidth: CleanerLayout.contentWidth)
                Divider()

            }
            .fixedSize(horizontal: false, vertical: true)

            Group {
                switch selectedTab {
                case .overview:
                    JobOverviewView(
                        job: job,
                        preferences: preferences,
                        optionsDisabled: job.status.isBusy || isBatchBusy
                    )
                case .metadata:
                    MetadataEditorView(job: job, preferences: preferences,
                                       disabled: job.status.isBusy || isBatchBusy, draft: $metadataDraft,
                                       onApply: onEditMetadata, onEditWordTraces: onEditWordTraces)
                case .preview:
                    FilePreviewView(job: job)
                }
            }
            .id(job.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: job.id) { _, _ in metadataDraft = [:] }
        .onChange(of: job.stagedOutputURL) { _, _ in metadataDraft = [:] }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                CleanerSymbol(systemImage: job.kind.systemImage, size: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(job.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
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

                Spacer(minLength: 12)

                Button(action: onClean) {
                    Label(job.cleaningOptions?.metadataEdits == nil ? "Clean Copy" : "Clean Original", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!job.status.canClean || job.status.isBusy || isBatchBusy)
                .help("Creates a fresh cleaned copy from the original. Clean first, then edit metadata to keep both changes.")
                .accessibilityIdentifier("detail.clean")
            }
            .controlSize(.large)

            HStack(spacing: 10) {
                StatusBadge(status: job.status)
                    .accessibilityIdentifier("detail.status")
                Text(job.kind.displayName)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button("Inspect", action: onInspect)
                    .disabled(job.status.isBusy || isBatchBusy)
                    .accessibilityIdentifier("detail.inspect")

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
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxWidth: CleanerLayout.contentWidth)
    }
}

private struct StatusBadge: View {
    let status: CleanerJobStatus

    var body: some View {
        Label {
            Text(status.label).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: status.systemImage)
        }
            .font(.caption.weight(.medium))
            .foregroundStyle(status.tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.tint.opacity(0.1), in: Capsule())
    }
}

private struct JobOverviewView: View {
    let job: CleanerJob
    @Bindable var preferences: AppPreferences
    let optionsDisabled: Bool
    @State private var rawReportExpanded = false
    @State private var settingsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectionSummaryView(job: job)

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

                if let report = job.currentInspection {
                    ReportCard(title: job.stagedOutputURL == nil ? "Inspection" : "Result inspection", report: report)
                } else if !job.status.isBusy {
                    NoticeCard(
                        title: "Not inspected yet",
                        message: "Inspection is read-only and runs automatically when a supported file is added.",
                        systemImage: "magnifyingglass"
                    )
                }

                if let report = job.currentInspection, report.raw["c2pa"] != nil {
                    ContentCredentialsCard(report: report)
                }

                DisclosureGroup("Cleaning settings", isExpanded: $settingsExpanded) {
                    VStack(spacing: 16) {
                        CurrentCleaningOptionsCard(preferences: preferences)
                        if job.sourceURL.pathExtension.lowercased() == "pdf" {
                            PDFCleaningCard(job: job, preferences: preferences, optionsDisabled: optionsDisabled)
                        }
                    }.padding(.top, 12)
                }
                .font(.subheadline.weight(.medium))
                .disabled(optionsDisabled)

                if let cleanReport = job.cleanReport {
                    CleanActionsCard(report: cleanReport)
                }

                if job.stagedOutputURL != nil {
                    if job.postCleanInspection == nil {
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)

                Text("A clean report describes only the checks that ran. It is not a universal certificate that no watermark remains.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: CleanerLayout.contentWidth, alignment: .leading)
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
                CleanerCardHeading(title: "Options for the next clean", systemImage: "slider.horizontal.3")
                Spacer()
                SettingsLink {
                    Text("All Settings")
                }
                .font(.caption)
                .buttonStyle(.link)
            }

            Divider().opacity(0.5)

            Toggle(isOn: $preferences.keepNonAIMetadata) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Preserve unrelated metadata")
                        .fontWeight(.medium)
                    Text("Keep ordinary author, date, camera, and document metadata while removing recognized provenance fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Preserve unrelated metadata")

            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Normalize unusual spaces", isOn: $preferences.normalizeSpaces)
                    Text("Off by default because non-breaking and narrow spaces can be meaningful typography.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .cleanerSurface()
    }
}

private struct ReportCard: View {
    let title: String
    let report: WatermarkReport
    @State private var notesExpanded = false

    private var reportTint: Color {
        report.inspectionIncomplete || report.hasActionableFindings ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CleanerCardHeading(title: title, systemImage: "doc.text.magnifyingglass", tint: reportTint)
                Spacer()
                if report.inspectionIncomplete {
                    Label("Incomplete", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if report.hasActionableFindings {
                    Label("Actionable findings", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("No actionable findings", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.5)

            if report.findings.isEmpty {
                Text("No confirmed or probable provenance marks were reported by the available checks.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.findings) { finding in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: finding.confidence.systemImage)
                            .foregroundStyle(finding.confidence <= .probable ? Color.orange : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.message)
                                .textSelection(.enabled)
                            Text(finding.confidence.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            if !report.notes.isEmpty {
                DisclosureGroup("About these checks", isExpanded: $notesExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .cleanerSurface()
    }
}

private struct CleanActionsCard: View {
    let report: WatermarkReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CleanerCardHeading(title: "Applied changes", systemImage: "checkmark", tint: .green)

            Divider().opacity(0.5)

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
        .padding(20)
        .cleanerSurface()
    }
}

private struct NoticeCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CleanerSymbol(systemImage: systemImage, tint: .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .cleanerSurface()
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
        if let metadataEdits { return "Updated \(metadataEdits.count) descriptive metadata fields on the current copy." }
        if let wordTraces { return wordTraces.summary }
        let metadata = stripAllMetadata
            ? "all removable metadata requested"
            : "unrelated metadata preserved"
        let spaces = normalizeSpaces ? "spaces normalized" : "typography preserved"
        return "\(metadata.capitalized); \(spaces); PDF deep-image mode: \(deepImages)."
    }
}
