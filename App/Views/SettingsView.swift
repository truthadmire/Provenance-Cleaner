import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: AppStore

    var body: some View {
        TabView {
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

            Form {
                Section {
                    Label("Everything is processed on this Mac", systemImage: "lock")
                    Text("The app has no network access. It removes markers it can find reliably and doesn't call any online service.")
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
}

struct NoticesView: View {
    private let notices = Self.loadNotices()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Provenance Cleaner")
                    .font(Clay.heading2)
                    .foregroundStyle(Clay.ink)
                Text("\(version) · Licenses and third-party notices")
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
            return "Third-party notices couldn't be loaded. See THIRD_PARTY_NOTICES.md in the release package."
        }
        return text
    }
}
