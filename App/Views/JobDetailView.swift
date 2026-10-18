import SwiftUI
import UniformTypeIdentifiers

enum JobDetailTab: String, CaseIterable, Identifiable {
    case findings = "Findings"
    case changes = "Changes"
    case review = "Review"

    var id: String { rawValue }
}

struct JobDetailView: View {
    @Bindable var store: AppStore
    let job: CleanerJob
    @Binding var selectedTab: JobDetailTab
    var onSaveCopy: () -> Void
    var onReplaceOriginal: () -> Void

    var body: some View {
        // The header owns its layout space so scrolled content never draws
        // behind it, and each file and tab starts at the top.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Clay.space4) {
                header
                JobVerdictBanner(job: job, onReveal: revealSaved)
                    .accessibilityIdentifier("detail.status")
                ClayTabBar(
                    tabs: JobDetailTab.allCases,
                    selection: $selectedTab,
                    title: \.rawValue,
                    badge: badge(for:),
                    identifier: { "detail.tab.\($0.rawValue.lowercased())" }
                )
            }
            .padding(.horizontal, Clay.space8)
            .padding(.top, Clay.space6)
            .frame(maxWidth: Clay.contentWidth + 2 * Clay.space8)
            .frame(maxWidth: .infinity)

            Rectangle().fill(Clay.hairline).frame(height: 1)

            ScrollView {
                Group {
                    switch selectedTab {
                    case .findings:
                        FindingsTabView(job: job, onInspect: inspect, onShowChanges: { selectedTab = .changes })
                    case .changes:
                        ChangesTabView(store: store, job: job)
                    case .review:
                        ReviewTabView(
                            store: store,
                            job: job,
                            onSaveCopy: onSaveCopy,
                            onReplaceOriginal: onReplaceOriginal,
                            onShowChanges: { selectedTab = .changes }
                        )
                    }
                }
                .padding(.horizontal, Clay.space8)
                .padding(.vertical, Clay.space6)
                .frame(maxWidth: Clay.contentWidth + 2 * Clay.space8)
                .frame(maxWidth: .infinity)
            }
            .id("\(job.id)-\(selectedTab.rawValue)")
        }
        .background(Clay.ivory)
        .onChange(of: job.resultRevision) { _, _ in selectedTab = .review }
        .onChange(of: job.id) { _, _ in
            selectedTab = job.stagedOutputURL == nil ? .findings : .review
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Clay.space4) {
            ClayIconTile(systemImage: job.kind.systemImage, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName)
                    .font(Clay.heading2)
                    .foregroundStyle(Clay.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(fileFacts)
                        .lineLimit(1)
                    Text("·").accessibilityHidden(true)
                    Button {
                        FilePanelService.reveal(job.sourceURL)
                    } label: {
                        Text("In \(job.sourceURL.deletingLastPathComponent().lastPathComponent)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(ClayLinkButtonStyle())
                    .help("Show in Finder: \(job.sourceURL.deletingLastPathComponent().path)")
                    .accessibilityLabel("Show original in Finder")
                }
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
            }

            Spacer(minLength: Clay.space4)

            HStack(spacing: Clay.space2) {
                if let replacement = job.replacement {
                    Button {
                        FilePanelService.reveal(replacement.backupURL)
                    } label: {
                        Label("Show backup", systemImage: "folder")
                    }
                    .buttonStyle(ClayButtonStyle(kind: .secondary, isLarge: true))
                    .help("Show \(replacement.backupURL.lastPathComponent) in Finder")
                    .accessibilityIdentifier("detail.show-backup")
                } else {
                    Button(action: inspect) {
                        Label("Check again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ClayButtonStyle(kind: .secondary, isLarge: true))
                    .disabled(job.status.isBusy || store.isBusy || job.kind == .unknown)
                    .help("Check the original again, and the copy if there is one")
                    .accessibilityIdentifier("detail.inspect")

                    primaryAction
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if job.status == .cleaning {
            Button {} label: {
                HStack(spacing: Clay.space2) {
                    ProgressView().controlSize(.small)
                    Text("Creating copy…")
                }
            }
            .buttonStyle(ClayButtonStyle(kind: .primary, isLarge: true))
            .disabled(true)
        } else if job.canExport, !store.copyNeedsUpdate(job) {
            Button(job.isSaved ? "Save again…" : "Save copy…", action: onSaveCopy)
                .buttonStyle(ClayButtonStyle(kind: .primary, isLarge: true))
                .disabled(store.isBusy)
                .help("Save the reviewed copy as a new file. The original isn't changed.")
                .accessibilityIdentifier("detail.export")
        } else {
            Button(job.canExport ? "Update copy" : "Create copy") {
                Task { await store.createCopy(jobID: job.id) }
            }
            .buttonStyle(ClayButtonStyle(kind: .primary, isLarge: true))
            .disabled(!store.canCreateCopy(job) || store.isBusy)
            .help(createHelp)
            .accessibilityIdentifier("detail.clean")
        }
    }

    private var createHelp: String {
        if job.plan.isEmpty { return "Choose at least one change on the Changes tab." }
        return "Make a copy of the original with the changes on the Changes tab."
    }

    private var fileFacts: String {
        let short = ["docx": "Word document", "xlsx": "Excel workbook", "pptx": "PowerPoint presentation",
                     "pdf": "PDF document", "md": "Markdown", "markdown": "Markdown", "txt": "Plain text"]
        let type = short[job.fileExtension]
            ?? UTType(filenameExtension: job.fileExtension)?.localizedDescription
            ?? job.kind.displayName
        let name = type.prefix(1).uppercased() + type.dropFirst()
        guard let size = (try? job.sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return name }
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    private func badge(for tab: JobDetailTab) -> String? {
        switch tab {
        case .findings:
            let count = job.inspection?.actionableFindings.count ?? 0
            return count > 0 ? String(count) : nil
        case .changes:
            let count = store.buildSteps(for: job).count
            return count > 0 ? String(count) : nil
        case .review:
            return nil
        }
    }

    private func inspect() {
        Task { await store.inspect(jobID: job.id) }
    }

    private func revealSaved() {
        if let backup = job.replacement?.backupURL {
            FilePanelService.reveal(backup)
        } else if let saved = job.savedCopies.last {
            FilePanelService.reveal(saved)
        }
    }
}

// MARK: - Verdict

/// The one place a file's state is summarised: what we know and what to do next.
struct JobVerdictBanner: View {
    let job: CleanerJob
    var onReveal: () -> Void

    var body: some View {
        let verdict = JobVerdict(job: job)
        ClayBanner(
            tone: verdict.tone,
            title: verdict.title,
            message: verdict.message,
            showsProgress: job.status.isBusy
        ) {
            if !job.status.isBusy, job.isSaved || job.isReplaced {
                Button("Show in Finder", action: onReveal)
                    .buttonStyle(ClayLinkButtonStyle())
            }
        }
    }
}

struct JobVerdict {
    let tone: ClayTone
    let title: String
    let message: String?

    init(job: CleanerJob) {
        let base = Self(status: job)
        guard !job.status.isBusy else {
            self = base
            return
        }
        // A save or replace never hides a warning about the copy itself.
        let caution = base.tone == .warning ? " Note: \(base.title.prefix(1).lowercased() + base.title.dropFirst())." : ""
        if let replacement = job.replacement {
            tone = base.tone == .warning ? .warning : .success
            title = "Original replaced"
            message = "The previous version is \(replacement.backupURL.lastPathComponent)."
                + (replacement.removedDownloadSource ? " Its download-source record was not carried over." : "")
                + caution
        } else if let saved = job.savedCopies.last {
            tone = base.tone == .warning ? .warning : .success
            title = "Saved as \(saved.lastPathComponent)"
            message = "The original is unchanged." + caution
        } else {
            self = base
        }
    }

    private init(status job: CleanerJob) {
        let hasCopy = job.stagedOutputURL != nil
        switch job.status {
        case .queued:
            (tone, title, message) = (.neutral, "Waiting to be checked", nil)
        case .inspecting:
            (tone, title, message) = (
                .progress, "Checking this file…",
                "Looking for content credentials, provenance metadata and invisible characters."
            )
        case .cleaning:
            (tone, title, message) = (
                .progress, job.activeStep?.progressTitle ?? "Creating your copy…",
                "Your original isn't changed."
            )
        case let .unsupported(reason):
            (tone, title, message) = (.neutral, "Not supported", reason)
        case let .failed(reason):
            (tone, title, message) = (
                .danger, "Something went wrong",
                hasCopy ? "\(reason) Your previous copy is unchanged." : reason
            )
        case .cancelled:
            (tone, title, message) = (
                .neutral, "Stopped",
                hasCopy ? "Your previous copy is unchanged." : "Nothing was changed."
            )
        case .inspectedClean:
            (tone, title, message) = (
                .success, "No provenance markers found",
                "The available checks found nothing to remove. You can still change properties and create a copy."
            )
        case let .findings(count):
            let report = job.inspection
            (tone, title, message) = (
                .warning, "\(count) provenance marker\(count == 1 ? "" : "s") found",
                Self.categorySentence(report).map { "\($0) Create a copy to remove them." }
                    ?? "Create a copy to remove them."
            )
        case let .inspectionIncomplete(count):
            (tone, title, message) = (
                .warning,
                count > 0 ? "\(count) marker\(count == 1 ? "" : "s") found, but checking didn't finish" : "Checking didn't finish",
                Self.reasonSentence(job.inspection?.incompleteReasons ?? [])
            )
        case let .readyToExport(remaining):
            if remaining > 0 {
                (tone, title, message) = (
                    .warning, "Your copy is ready, but \(remaining) marker\(remaining == 1 ? "" : "s") remain\(remaining == 1 ? "s" : "")",
                    "See what's left on the Review tab before you save."
                )
            } else {
                (tone, title, message) = (
                    .success, "Your copy is ready",
                    "The checks found nothing left to remove. Review the changes, then save the copy."
                )
            }
        case .cleanedInspectionIncomplete:
            (tone, title, message) = (
                .warning, "Your copy is ready, but checking it didn't finish",
                Self.reasonSentence(ReviewTabView.mergedReasons(job.postCleanInspection, job.cleanReport))
                    ?? "Review the copy carefully before you save it."
            )
        }
    }

    private static func categorySentence(_ report: WatermarkReport?) -> String? {
        let categories = (report?.actionableFindings ?? []).map(\.category)
        var unique: [FindingCategory] = []
        for category in categories where !unique.contains(category) { unique.append(category) }
        guard !unique.isEmpty else { return nil }
        let names = unique.map { $0.title.lowercased() }
        let list = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "In \(list)."
    }

    private static func reasonSentence(_ reasons: [String]) -> String? {
        guard let first = reasons.first else { return nil }
        let extra = reasons.count - 1
        return extra > 0 ? "\(first) (\(extra) more below.)" : first
    }
}
