import SwiftUI

/// Confirms what's about to leave the Mac. Shown before every AI review.
struct AIReviewSheet: View {
    @Bindable var store: AppStore
    let jobID: CleanerJob.ID
    let scan: PromptInjectionScan
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var selected: Set<AIProvider> = []

    private var ready: [AIProvider] { store.aiProvidersReady() }

    private var chosen: [AIProvider] { ready.filter(selected.contains) }

    private var characters: Int { scan.reviewText.count }

    private var requests: Int { AIReviewPrompt.chunks(of: scan.reviewText).count }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            Text("Review with AI")
                .font(Clay.heading2)
                .foregroundStyle(Clay.ink)
            if ready.isEmpty {
                Text("Add an API key for at least one provider in Settings, under AI review.")
                    .font(Clay.body)
                    .foregroundStyle(Clay.inkMuted)
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
                providerList
                disclosure
                ClayDisclosure(title: "Show what will be sent") {
                    ScrollView {
                        Text(verbatim: "Offline findings:\n\(AIReviewPrompt.offlineSummary(of: scan))\n\n\(scan.reviewText.prefix(20_000))")
                            .font(Clay.code)
                            .foregroundStyle(Clay.inkMuted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Send to \(chosen.count) provider\(chosen.count == 1 ? "" : "s")") {
                        let providers = chosen
                        dismiss()
                        Task { await store.reviewWithAI(jobID: jobID, providers: providers) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("aiReview.send")
                }
            }
        }
        .padding(Clay.space6)
        .frame(width: 500)
        .background(Clay.ivory)
        .onAppear { selected = Set(ready.prefix(1)) }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: Clay.space2) {
            ForEach(ready) { provider in
                Toggle(isOn: Binding(
                    get: { selected.contains(provider) },
                    set: { isOn in
                        if isOn { selected.insert(provider) } else { selected.remove(provider) }
                    }
                )) {
                    Text(verbatim: "\(provider.displayName) · \(store.preferences.aiSettings(for: provider).model)")
                        .font(Clay.body)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var disclosure: some View {
        let companies = chosen.isEmpty ? "the providers you choose" : chosen.map(\.company).formatted(.list(type: .and))
        return VStack(alignment: .leading, spacing: Clay.space2) {
            Text("This file's extracted text, including hidden text, comments and metadata, and a summary of the offline findings go to \(companies) under your API keys, and those companies' terms and pricing apply. The file itself isn't sent.")
                .font(Clay.body)
                .foregroundStyle(Clay.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("About \(characters.formatted()) characters, roughly \((characters / 4).formatted()) tokens, in \(requests) request\(requests == 1 ? "" : "s") per provider.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
            if scan.reviewTextTruncated {
                Text("Only the first 400,000 characters are sent, with hidden text and comments first.")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension AIProvider {
    /// The colour of this provider's words in the prompt-injection card.
    var tint: Color {
        switch self {
        case .claude: Clay.aiClaude
        case .openAI: Clay.aiOpenAI
        case .gemini: Clay.aiGemini
        case .deepSeek: Clay.aiDeepSeek
        case .glm: Clay.aiGLM
        case .qwen: Clay.aiQwen
        }
    }
}

/// One provider's review inside the prompt-injection card. Advisory: nothing acts on it.
struct AIReviewResultView: View {
    let review: AIProviderReview

    private var tint: Color { review.provider.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(review.provider.displayName) · \(review.model)")
                    .font(Clay.captionMedium)
                    .foregroundStyle(tint)
                Spacer()
                badge
            }
            switch review.state {
            case .running:
                HStack(spacing: Clay.space2) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the provider…")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                }
            case let .failed(message):
                Text(message)
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            case let .finished(outcome):
                ForEach(outcome.findings) { finding in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(finding.technique): \(finding.explanation)")
                            .font(Clay.body)
                            .foregroundStyle(tint)
                        Text(verbatim: finding.quote)
                            .font(Clay.code)
                            .foregroundStyle(tint)
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if outcome.findings.isEmpty {
                    Text(outcome.removedClaims > 0 ? "This model reported nothing it could back up with a quote." : "This model found nothing.")
                        .font(Clay.caption)
                        .foregroundStyle(tint)
                }
                if outcome.removedClaims > 0 {
                    Text("\(outcome.removedClaims) claim\(outcome.removedClaims == 1 ? " was" : "s were") left out because the quoted text isn't in this file.")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch review.state {
        case .running:
            EmptyView()
        case .failed:
            ClayBadge(text: "No answer", tone: .neutral)
        case let .finished(outcome):
            switch outcome.verdict {
            case .none: ClayBadge(text: outcome.verdict.title, tone: .success)
            case .suspicious: ClayBadge(text: outcome.verdict.title, tone: .warning)
            case .likely: ClayBadge(text: outcome.verdict.title, tone: .danger)
            }
        }
    }
}

/// Keys and model choices for the optional AI review.
struct AIReviewSettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: AppStore

    var body: some View {
        Form {
            Section {
                Text("Optional. Add a key for any provider you want to use. Nothing is sent until you press Review with AI on a file and confirm. Keys stay in your Keychain.")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
            ForEach(AIProvider.allCases) { provider in
                AIProviderSettingsSection(provider: provider, preferences: preferences, store: store)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AIProviderSettingsSection: View {
    let provider: AIProvider
    @Bindable var preferences: AppPreferences
    @Bindable var store: AppStore
    @State private var hasKey = false
    @State private var draft = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var isTesting = false

    private var settings: Binding<AIProviderSettings> {
        Binding(
            get: { preferences.aiSettings(for: provider) },
            set: { preferences.setAISettings($0, for: provider) }
        )
    }

    var body: some View {
        Section {
            if hasKey {
                LabeledContent("API key") {
                    HStack {
                        Text("Saved in Keychain")
                            .foregroundStyle(Clay.inkMuted)
                        Button("Remove", role: .destructive, action: removeKey)
                    }
                }
                Toggle("Offer for reviews", isOn: settings.enabled)
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField("API key", text: $draft, prompt: Text("Paste your key"))
                            .labelsHidden()
                            .accessibilityIdentifier("settings.ai.key.\(provider.rawValue)")
                        Button("Save", action: saveKey)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            LabeledContent("Model") {
                HStack {
                    TextField("Model", text: settings.model)
                        .labelsHidden()
                        .autocorrectionDisabled()
                    Menu("Suggestions") {
                        ForEach(provider.suggestedModels, id: \.self) { model in
                            Button(model) { settings.wrappedValue.model = model }
                        }
                    }
                    .fixedSize()
                }
            }
            if provider.endpoints.count > 1 {
                Picker("Region", selection: settings.endpointID) {
                    ForEach(provider.endpoints) { endpoint in
                        Text(endpoint.name).tag(endpoint.id)
                    }
                }
            }
            if hasKey {
                HStack {
                    Button("Test", action: test)
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let message {
                Text(message)
                    .font(Clay.caption)
                    .foregroundStyle(messageIsError ? Clay.danger : Clay.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(verbatim: provider.company == provider.displayName ? provider.displayName : "\(provider.displayName) (\(provider.company))")
        }
        .onAppear { hasKey = store.apiKeys.hasKey(for: provider) }
    }

    private func saveKey() {
        do {
            try store.apiKeys.save(draft.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
            draft = ""
            hasKey = true
            show(nil)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func removeKey() {
        do {
            try store.apiKeys.delete(for: provider)
            hasKey = false
            show(nil)
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    private func test() {
        isTesting = true
        show(nil)
        Task {
            let failure = await store.testAIProvider(provider)
            isTesting = false
            if let failure {
                show(failure, isError: true)
            } else {
                show("It works: \(provider.displayName) answered in the expected form.")
            }
        }
    }

    private func show(_ text: String?, isError: Bool = false) {
        message = text
        messageIsError = isError
    }
}
