import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: AppStore
    @State private var showingRelaunchConfirmation = false
    @State private var relaunchFailure: String?

    var body: some View {
        TabView {
            Form {
                languageSection
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }

            Form {
                Section {
                    Toggle("Keep ordinary metadata", isOn: $preferences.keepNonAIMetadata)
                    Text(
                        preferences.keepNonAIMetadata
                            ? "Removes only fields related to AI generation or provenance, where the format allows. Office files (DOCX, XLSX, PPTX) always lose author, last saved by, subject, keywords, description and company."
                            : "Strips all removable metadata, including camera, location, copyright and descriptive fields."
                    )
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                } header: {
                    Text("Metadata")
                }

                Section {
                    Toggle("Remove invisible characters in document text", isOn: $preferences.alsoLayerAText)
                    Toggle("Replace unusual spaces", isOn: $preferences.normalizeSpaces)
                    Text("Replacing spaces is off by default: non-breaking and narrow spaces can be correct typography, for example in French.")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                } header: {
                    Text("Text")
                }

                Section {
                    Picker("Images inside PDFs", selection: $preferences.deepImageMode) {
                        ForEach(AppPreferences.DeepImageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text(preferences.deepImageMode.explanation)
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                    if let capabilities = store.capabilities {
                        Label(
                            capabilities.supportsPDFDeepCleaning
                                ? "The image engine is available"
                                : "The image engine isn't available, so only document metadata can be cleaned",
                            systemImage: capabilities.supportsPDFDeepCleaning ? "checkmark.circle" : "exclamationmark.triangle"
                        )
                        .font(Clay.caption)
                        .foregroundStyle(capabilities.supportsPDFDeepCleaning ? Clay.success : Clay.warning)
                    }
                } header: {
                    Text("PDF")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cleaning", systemImage: "wand.and.stars")
            }

            AIReviewSettingsView(preferences: preferences, store: store)
                .tabItem {
                    Label("AI review", systemImage: "sparkle.magnifyingglass")
                }

            Form {
                Section {
                    Label("Cleaning and checking happen on this Mac", systemImage: "lock")
                    Text("The app removes markers it can find reliably, without any online service. It goes online only for an AI review: when you run one and confirm, the file's extracted text goes to the providers you chose, with your own keys.")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                } header: {
                    Text("Privacy")
                }

                Section {
                    Text("Use Provenance Cleaner only with files you own or are allowed to change. Removing provenance doesn't change who made a file or who may use it.")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                } header: {
                    Text("Responsible use")
                }

                Section {
                    if store.capabilities != nil {
                        Label("Engine available", systemImage: "checkmark.circle")
                            .foregroundStyle(Clay.success)
                    } else if let message = store.engineAvailabilityMessage {
                        Label("Engine unavailable", systemImage: "xmark.octagon")
                            .foregroundStyle(Clay.danger)
                            .accessibilityIdentifier("settings.engine-unavailable")
                        Text(message)
                            .font(Clay.caption)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.engine-error")
                    } else {
                        ProgressView("Checking the engine…")
                    }
                    DisclosureGroup("Technical details") {
                        LabeledContent("Bundled helper") {
                            Text(BundledWatermarkEngine.relativeBundledHelperPath)
                                .font(Clay.code)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Development override") {
                            Text(BundledWatermarkEngine.helperOverrideEnvironmentKey)
                                .font(Clay.code)
                                .textSelection(.enabled)
                        }
                        if let capabilities = store.capabilities {
                            Text(capabilities.report.raw.prettyPrinted)
                                .font(Clay.code)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Button("Check engine again") {
                        Task { await store.refreshCapabilities() }
                    }
                } header: {
                    Text("Diagnostics")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
        }
        .tint(Clay.accent)
        .scenePadding()
        .frame(width: 600, height: 500)
        .task {
            if store.capabilities == nil {
                await store.refreshCapabilities()
            }
        }
    }

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            }
            .accessibilityIdentifier("settings.language")
            if preferences.languageNeedsRelaunch {
                Label("Relaunch Provenance Cleaner to use this language.", systemImage: "arrow.clockwise")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.warning)
                    .accessibilityIdentifier("settings.language.pending")
                Button("Relaunch now") {
                    if store.jobs.isEmpty {
                        relaunch()
                    } else {
                        showingRelaunchConfirmation = true
                    }
                }
                .disabled(store.isBusy)
                .accessibilityIdentifier("settings.language.relaunch")
            }
            if let relaunchFailure {
                Text(String(localized: "The app couldn't relaunch: \(relaunchFailure)"))
                    .font(Clay.caption)
                    .foregroundStyle(Clay.danger)
            }
            Text("System default follows the language order in System Settings. The language applies to the whole app the next time it opens, so nothing is left half translated.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
            Text("Translations haven't been reviewed by a native speaker. Text from your files and from AI models is never translated. Technical findings from the cleaning engine, error messages from bundled tools and the third-party notices stay in English.")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
        } header: {
            Text("Language")
        }
        .confirmationDialog(
            "Relaunch now?",
            isPresented: $showingRelaunchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Relaunch") { relaunch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file list is cleared, and copies you haven't saved are lost. Your original files aren't changed.")
        }
    }

    private func relaunch() {
        relaunchFailure = nil
        AppRelauncher.relaunch { relaunchFailure = $0 }
    }
}

struct NoticesView: View {
    private let notices = Self.loadNotices()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Provenance Cleaner")
                    .font(Clay.heading2)
                    .foregroundStyle(Clay.ink)
                Text(String(localized: "\(version) · Licenses and third-party notices"))
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
            ScrollView {
                Text(notices)
                    .font(Clay.code)
                    .foregroundStyle(Clay.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Clay.space4)
            }
            .background(Clay.surface, in: RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous)
                    .strokeBorder(Clay.hairline, lineWidth: 1)
            }
        }
        .padding(Clay.space6)
        .background(Clay.ivory)
    }

    private static func loadNotices() -> String {
        guard
            let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return String(localized: "Third-party notices couldn't be loaded. See THIRD_PARTY_NOTICES.md in the release package.")
        }
        return text
    }
}
