import SwiftUI

/// The prompt-injection check for one file. Excerpts come from the file, so they
/// are always shown as plain text.
struct PromptInjectionCard: View {
    let state: InjectionScanState
    var canScan: Bool
    var aiReviews: [AIProviderReview] = []
    var onScan: () -> Void
    var onReviewWithAI: () -> Void = {}

    private static let title = String(localized: "Prompt injection")
    private static let purpose = String(localized: "Instructions hidden from you but readable by an AI assistant that opens this file.")

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            switch state {
            case .notScanned:
                ClayCardHeader(title: Self.title, subtitle: Self.purpose) {
                    scanButton(String(localized: "Check"))
                }
            case .scanning:
                ClayCardHeader(title: Self.title, subtitle: Self.purpose)
                HStack(spacing: Clay.space3) {
                    ProgressView().controlSize(.small)
                    Text("Reading the file's text…")
                        .font(Clay.body)
                        .foregroundStyle(Clay.inkMuted)
                }
            case let .failed(message):
                ClayCardHeader(title: Self.title, subtitle: Self.purpose) {
                    scanButton(String(localized: "Try again"))
                }
                explanation(message)
            case let .finished(scan):
                finished(scan)
            }
        }
        .clayCard()
        .accessibilityIdentifier("findings.promptInjection")
    }

    @ViewBuilder
    private func finished(_ scan: PromptInjectionScan) -> some View {
        if !scan.available {
            ClayCardHeader(title: Self.title, subtitle: Self.purpose) {
                ClayBadge(text: String(localized: "Not checked"), tone: .warning)
            }
            explanation(scan.reason)
            scanButton(String(localized: "Check again"))
        } else {
            ClayCardHeader(title: Self.title, subtitle: subtitle(for: scan.verdict)) {
                ClayBadge(text: scan.verdict.title, tone: tone(for: scan.verdict))
            }
            ForEach(scan.mainGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: Clay.space2) {
                    Text(group.title)
                        .font(Clay.captionMedium)
                        .foregroundStyle(Clay.inkMuted)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(group.findings) { finding in
                        InjectionFindingRow(finding: finding)
                    }
                }
            }
            if !scan.lesserFindings.isEmpty {
                let count = scan.lesserFindings.count
                ClayDisclosure(title: String(localized: "\(count) lesser notes")) {
                    VStack(alignment: .leading, spacing: Clay.space2) {
                        ForEach(scan.lesserFindings) { finding in
                            InjectionFindingRow(finding: finding)
                        }
                    }
                }
            }
            if scan.findingsTotal > scan.findings.count {
                explanation(String(localized: "Showing the first \(scan.findings.count) of \(scan.findingsTotal) signs."))
            }
            ForEach(scan.notes, id: \.self) { note in
                explanation(note)
            }
            explanation(String(localized: "This check only reports. Creating a copy can remove invisible characters and some metadata, but hidden text and comments stay in it."))
            if !aiReviews.isEmpty {
                Rectangle().fill(Clay.hairline).frame(height: 1)
                Text("AI review")
                    .font(Clay.captionMedium)
                    .foregroundStyle(Clay.inkMuted)
                    .accessibilityAddTraits(.isHeader)
                ForEach(aiReviews) { review in
                    AIReviewResultView(review: review)
                }
                explanation(String(localized: "A second opinion from the models you chose. It can miss things or be misled by the file, so it doesn't replace the checks above."))
            }
            HStack(spacing: Clay.space2) {
                scanButton(String(localized: "Check again"))
                Button("Review with AI…", action: onReviewWithAI)
                    .buttonStyle(.clayGhost)
                    .disabled(!canScan)
                    .accessibilityIdentifier("findings.promptInjection.reviewWithAI")
            }
        }
    }

    private func subtitle(for verdict: PromptInjectionScan.Verdict) -> String {
        switch verdict {
        case .none:
            String(localized: "These checks found no hidden instructions. They can't rule out every technique.")
        case .suspicious:
            String(localized: "Worth reading before an AI assistant opens this file. It may have an innocent explanation.")
        case .likely:
            String(localized: "Text here is hidden from you or written to instruct an AI. Avoid giving this file to an AI assistant until you've read it.")
        }
    }

    private func tone(for verdict: PromptInjectionScan.Verdict) -> ClayTone {
        switch verdict {
        case .none: .success
        case .suspicious: .warning
        case .likely: .danger
        }
    }

    private func scanButton(_ title: String) -> some View {
        Button(title, action: onScan)
            .buttonStyle(.clayGhost)
            .disabled(!canScan)
            .accessibilityIdentifier("findings.promptInjection.scan")
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(Clay.caption)
            .foregroundStyle(Clay.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InjectionFindingRow: View {
    let finding: PromptInjectionScan.Finding

    private var tone: ClayTone {
        switch finding.severity {
        case .high: .danger
        case .medium: .warning
        case .info: .neutral
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Clay.space3) {
            Circle()
                .fill(tone.foreground)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: finding.localizedSummary)
                    .font(Clay.body)
                    .foregroundStyle(Clay.ink)
                Text(verbatim: finding.localizedLocation)
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                if let decoded = finding.decoded {
                    Text(verbatim: String(localized: "Decoded: \(decoded)"))
                        .font(Clay.code)
                        .foregroundStyle(Clay.ink)
                } else if !finding.excerpt.isEmpty {
                    Text(verbatim: finding.excerpt)
                        .font(Clay.code)
                        .foregroundStyle(Clay.inkMuted)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
