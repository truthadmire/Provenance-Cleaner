import SwiftUI

struct ContentCredentialsCard: View {
    let report: WatermarkReport
    @State private var imagesExpanded = false
    private var raw: JSONValue? { report.raw["c2pa"] }
    private var assets: [JSONValue] { raw?["embeddedAssets"]?.arrayValue ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                CleanerCardHeading(title: "Content Credentials", systemImage: "checkmark.seal")
                Spacer()
                Text(report.credentialSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(report.credentialNeedsAttention ? Color.orange : Color.secondary)
            }
            if raw?["isContainer"]?.boolValue == true {
                Text("Document credential").font(.subheadline.weight(.semibold))
                CredentialVerificationView(raw: raw?["document"])
                Divider()
                DisclosureGroup(isExpanded: $imagesExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(assets.enumerated()), id: \.offset) { _, asset in
                            DisclosureGroup {
                                CredentialVerificationView(raw: asset).padding(.top, 12)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(asset["path"]?.stringValue ?? "Embedded image")
                                        .fontWeight(.medium).textSelection(.enabled)
                                    Text(WatermarkReport.credentialSummary(for: asset))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if assets.isEmpty { Text("No embedded media were inspected.").foregroundStyle(.secondary) }
                    }
                    .padding(.top, 14)
                } label: {
                    Text("Embedded media: \(Int(raw?["inspectedEmbeddedCount"]?.numberValue ?? 0)) / \(Int(raw?["embeddedCount"]?.numberValue ?? 0)) inspected")
                        .font(.subheadline.weight(.semibold))
                }
                ForEach(raw?["coverageErrors"]?.arrayValue?.compactMap(\.stringValue) ?? [], id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                Text(raw?["scope"]?.stringValue ?? "Offline inspection only.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                CredentialVerificationView(raw: raw, markersDetected: report.raw["has_c2pa"]?.boolValue == true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).cleanerSurface()
        .accessibilityIdentifier("credentials.card")
    }
}
