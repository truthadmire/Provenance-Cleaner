import SwiftUI

struct MetadataEditorView: View {
    let job: CleanerJob
    @Bindable var preferences: AppPreferences
    let disabled: Bool
    @Binding var draft: [String: String]
    var onApply: ([String: String]) -> Void
    var onEditWordTraces: () -> Void

    private var metadata: JSONValue? { job.currentInspection?.raw["metadata"] }
    private var fields: [MetadataField] { metadata?["fields"]?.arrayValue?.compactMap(MetadataField.init) ?? [] }
    private var edits: [String: String] {
        draft.filter { key, value in fields.contains { $0.id == key && $0.value != value } }
    }

    private var editsValid: Bool {
        edits.values.allSatisfy { value in
            value.unicodeScalars.count <= 4096 && !value.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        CleanerCardHeading(title: "Document properties", systemImage: "text.cursor")
                        Spacer()
                        Text(job.stagedOutputURL == nil ? "Original" : "Current result")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    if metadata?["available"]?.boolValue == true {
                        VStack(spacing: 16) {
                            ForEach(fields) { field in
                                HStack(alignment: .firstTextBaseline, spacing: 20) {
                                    Text(field.label)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 112, alignment: .leading)
                                    TextField("Not set", text: Binding(
                                        get: { draft[field.id] ?? field.value },
                                        set: { draft[field.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(field.label)
                                    .accessibilityIdentifier("metadata.\(field.id)")
                                }
                            }
                        }
                        .disabled(disabled || metadata?["editable"]?.boolValue != true)
                        Text("Leave a field empty to remove it. Unchanged fields are preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !editsValid {
                            Text("Use at most 4,096 characters per field and remove control characters.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Divider()
                        HStack {
                            Text(edits.isEmpty ? "No unsaved changes" : "\(edits.count) field\(edits.count == 1 ? "" : "s") changed")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset") { draft = [:] }
                                .disabled(edits.isEmpty || disabled)
                            Button("Apply to Copy") { onApply(edits) }
                                .buttonStyle(.borderedProminent)
                                .disabled(edits.isEmpty || !editsValid || disabled || metadata?["editable"]?.boolValue != true || !job.status.canClean)
                                .accessibilityIdentifier("metadata.apply")
                        }
                    }
                    Text(metadata?["note"]?.stringValue ?? "Inspect a file to read its editable metadata.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if job.sourceURL.pathExtension.lowercased() == "pdf" {
                        Text("PDF metadata updates are incremental. Earlier values may remain recoverable in the file; this editor is not a secure redaction tool.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24).cleanerSurface()

                if job.sourceURL.pathExtension.lowercased() == "docx" {
                    WordEditingTracesCard(job: job, preferences: preferences, optionsDisabled: disabled, onApply: onEditWordTraces)
                }
                Label("Changes are staged in a copy. Clean first, then edit properties to keep both changes.", systemImage: "doc.on.doc")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: CleanerLayout.contentWidth)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct MetadataField: Identifiable {
    let id: String
    let label: String
    let value: String
    init?(_ raw: JSONValue) {
        guard let id = raw["id"]?.stringValue, let label = raw["label"]?.stringValue else { return nil }
        self.id = id
        self.label = label
        self.value = raw["value"]?.stringValue ?? ""
    }
}
