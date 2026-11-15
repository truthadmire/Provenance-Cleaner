import SwiftUI

/// The optional online watermark check of an original image. Advisory: nothing
/// in the app acts on it.
struct OnlineProvenanceCard: View {
    let check: OnlineProvenanceCheck?
    var canCheck: Bool
    var onCheck: () -> Void

    private static let title = String(localized: "AI watermark (online)")
    private static let purpose = String(localized: "Ask OpenAI whether this image carries its SynthID watermark or content credentials from OpenAI.")

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            switch check?.state {
            case nil:
                ClayCardHeader(title: Self.title, subtitle: Self.purpose) {
                    checkButton(String(localized: "Check online…"))
                }
                explanation(String(localized: "Optional. The image is uploaded to OpenAI only after you confirm."))
            case .running:
                ClayCardHeader(title: Self.title, subtitle: Self.purpose)
                HStack(spacing: Clay.space3) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for OpenAI…")
                        .font(Clay.body)
                        .foregroundStyle(Clay.inkMuted)
                }
            case let .failed(message):
                ClayCardHeader(title: Self.title, subtitle: Self.purpose) {
                    checkButton(String(localized: "Try again…"))
                }
                explanation(message)
            case let .finished(result):
                finished(result)
            }
        }
        .clayCard()
        .accessibilityIdentifier("findings.onlineProvenance")
    }

    @ViewBuilder
    private func finished(_ result: ProvenanceCheckResult) -> some View {
        ClayCardHeader(title: Self.title, subtitle: subtitle(for: result)) {
            badge(for: result)
        }
        if result.signals.isEmpty {
            Text("OpenAI reported no checks that apply to this image.")
                .font(Clay.body)
                .foregroundStyle(Clay.inkMuted)
        } else {
            Grid(alignment: .leading, horizontalSpacing: Clay.space6, verticalSpacing: Clay.space2) {
                if let synthID = result.synthID {
                    ClayKeyValueRow(
                        key: String(localized: "SynthID watermark"),
                        value: synthID.detected ? String(localized: "Found") : String(localized: "Not found")
                    )
                }
                if let c2pa = result.c2pa {
                    ClayKeyValueRow(
                        key: String(localized: "OpenAI content credentials"),
                        value: c2pa.detected ? String(localized: "Found") : String(localized: "Not found")
                    )
                    if let state = c2pa.validationState, state != "not_present" {
                        ClayKeyValueRow(key: String(localized: "Signature"), value: Self.validationTitle(state))
                    }
                    if let issuer = c2pa.issuer {
                        ClayKeyValueRow(key: String(localized: "Issued by"), value: issuer)
                    }
                }
                if let model = result.signals.compactMap(\.model).first {
                    ClayKeyValueRow(key: String(localized: "Model"), value: model)
                }
                if let generated = result.signals.compactMap(\.generatedAt).first {
                    ClayKeyValueRow(key: String(localized: "Generated"), value: ClayDate.display(generated))
                }
            }
            .textSelection(.enabled)
        }
        if result.synthID?.detected == true {
            explanation(String(localized: "The watermark is in the pixels. Creating a copy removes metadata such as content credentials, but this watermark stays in the copy."))
        }
        if result.c2pa?.validationState == "invalid" {
            explanation(String(localized: "The credentials' signature is invalid, so OpenAI doesn't treat them as reliable evidence."))
        }
        explanation(String(localized: "Only OpenAI's own signals are checked. \"Not found\" doesn't mean the image wasn't made with AI: images from other companies' models, older OpenAI images and edited images may not register."))
        if let check {
            explanation(String(localized: "Checked online at \(check.checkedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: AppLocale.current))). The result isn't saved, and the same file isn't sent again."))
        }
    }

    private func subtitle(for result: ProvenanceCheckResult) -> String {
        if result.synthID?.detected == true {
            return String(localized: "OpenAI found its watermark: this image was very likely made or edited with an OpenAI model.")
        }
        if result.c2pa?.detected == true {
            return String(localized: "OpenAI found its own content credentials, which record that an OpenAI model made this image.")
        }
        return String(localized: "OpenAI found none of its signals in this image.")
    }

    @ViewBuilder
    private func badge(for result: ProvenanceCheckResult) -> some View {
        if result.synthID?.detected == true {
            ClayBadge(text: String(localized: "OpenAI watermark"), tone: .warning)
        } else if result.c2pa?.detected == true {
            ClayBadge(text: String(localized: "OpenAI credentials"), tone: .warning)
        } else {
            ClayBadge(text: String(localized: "No OpenAI signal"), tone: .neutral)
        }
    }

    static func validationTitle(_ state: String) -> String {
        switch state {
        case "trusted": String(localized: "Valid, from a trusted signer")
        case "valid": String(localized: "Valid")
        case "invalid": String(localized: "Invalid")
        default: state
        }
    }

    private func checkButton(_ title: String) -> some View {
        Button(title, action: onCheck)
            .buttonStyle(.clayGhost)
            .disabled(!canCheck)
            .accessibilityIdentifier("findings.onlineProvenance.check")
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .font(Clay.caption)
            .foregroundStyle(Clay.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Confirms what's about to leave the Mac. Shown before every online check.
struct OnlineProvenanceSheet: View {
    @Bindable var store: AppStore
    let job: CleanerJob
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    private var hasKey: Bool { store.apiKeys.hasKey(for: .openAI) }

    private var size: String? {
        (try? job.sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            Text("Check for an AI watermark online")
                .font(Clay.heading2)
                .foregroundStyle(Clay.ink)
            if !hasKey {
                Text("The check uses your OpenAI API key. Add one in Settings, under AI review.")
                    .font(Clay.body)
                    .foregroundStyle(Clay.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open Settings…") {
                        dismiss()
                        openSettings()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: Clay.space2) {
                    Text("This image goes to OpenAI under your API key, and OpenAI's terms and pricing apply. Only the image is sent, not its file name.")
                        .font(Clay.body)
                        .foregroundStyle(Clay.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let size {
                        Text(verbatim: "\(job.displayName) · \(size)")
                            .font(Clay.caption)
                            .foregroundStyle(Clay.inkMuted)
                    }
                    Text("OpenAI checks only for its own signals. Its terms don't allow repeated checks to remove or evade a watermark, so each file is checked once.")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Send to OpenAI") {
                        let id = job.id
                        dismiss()
                        Task { await store.checkProvenanceOnline(jobID: id) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onlineProvenance.send")
                }
            }
        }
        .padding(Clay.space6)
        .frame(width: 480)
        .background(Clay.ivory)
    }
}
