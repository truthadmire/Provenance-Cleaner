import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @Bindable var store: AppStore

    var body: some View {
        TabView {
            Form {
                Section("Metadata") {
                    Toggle("Preserve ordinary metadata", isOn: $preferences.keepNonAIMetadata)
                    Text(
                        preferences.keepNonAIMetadata
                            ? "Only metadata that looks related to AI generation or provenance is removed."
                            : "All removable metadata may be stripped, including camera, location, copyright, and descriptive fields."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section("Text") {
                    Toggle("Clean invisible Unicode in document text", isOn: $preferences.alsoLayerAText)
                    Toggle("Normalize unusual spaces", isOn: $preferences.normalizeSpaces)
                    Text("Space normalization is off by default because non-breaking spaces can be meaningful in French and other typography.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("PDF embedded images") {
                    Picker("Deep image handling", selection: $preferences.deepImageMode) {
                        ForEach(AppPreferences.DeepImageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("Ghostscript is intentionally not included. Document-level PDF cleanup uses ExifTool and qpdf, but provenance metadata inside some embedded images may remain. Every PDF result discloses this residual risk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Cleaning", systemImage: "wand.and.stars")
            }

            Form {
                Section("Local engine") {
                    LabeledContent("Bundled helper") {
                        Text(BundledWatermarkEngine.relativeBundledHelperPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("Development override") {
                        Text(BundledWatermarkEngine.helperOverrideEnvironmentKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if let capabilities = store.capabilities {
                        Label("Engine available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        DisclosureGroup("Capability report") {
                            Text(capabilities.report.raw.prettyPrinted)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let message = store.engineAvailabilityMessage {
                        Label("Engine unavailable", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settings.engine-unavailable")
                        Text(message)
                            .font(.caption)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.engine-error")
                    } else {
                        ProgressView("Checking engine…")
                    }
                    Button("Refresh Diagnostics") {
                        Task { await store.refreshCapabilities() }
                    }
                }

                Section("Privacy and scope") {
                    Label("Processing stays on this Mac", systemImage: "lock.shield")
                    Text("This app performs deterministic Unicode and provenance-metadata cleaning. It does not call remote model services or claim universal watermark removal.")
                        .foregroundStyle(.secondary)
                }

                Section("Responsible use") {
                    Text("Use Provenance Cleaner only with content you own or are authorized to modify. Cleaning provenance metadata does not change authorship or usage rights.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
        }
        .scenePadding()
        .frame(width: 580, height: 470)
        .task {
            if store.capabilities == nil {
                await store.refreshCapabilities()
            }
        }
    }
}

struct NoticesView: View {
    private let notices = Self.loadNotices()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Provenance Cleaner 0.1.0", systemImage: "doc.badge.gearshape")
                .font(.title2.weight(.semibold))
            Text("Licenses and third-party notices")
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                Text(notices)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(20)
    }

    private static func loadNotices() -> String {
        guard
            let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Third-party notices could not be loaded. See the release package for THIRD_PARTY_NOTICES.md."
        }
        return text
    }
}
