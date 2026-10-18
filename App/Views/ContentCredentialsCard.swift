import SwiftUI

struct ContentCredentialsCard: View {
    let report: WatermarkReport
    var subtitle: String?
    private var raw: JSONValue? { report.raw["c2pa"] }
    private var assets: [JSONValue] { raw?["embeddedAssets"]?.arrayValue ?? [] }

    private var summaryTone: ClayTone {
        switch report.credentialSummary {
        case "Validation failed": .danger
        case "Unable to verify", "Credentials detected", "Markers detected": .warning
        case "No credentials found": .success
        default: .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            ClayCardHeader(title: "Content credentials", subtitle: subtitle ?? "C2PA signatures, checked offline") {
                ClayBadge(text: report.credentialSummary, tone: summaryTone)
            }

            if raw?["isContainer"]?.boolValue == true {
                containerBody
            } else {
                CredentialVerificationView(raw: raw, markersDetected: report.raw["has_c2pa"]?.boolValue == true)
            }
        }
        .clayCard()
        .accessibilityIdentifier("credentials.card")
    }

    @ViewBuilder
    private var containerBody: some View {
        VStack(alignment: .leading, spacing: Clay.space2) {
            Text("The document")
                .font(Clay.captionMedium)
                .foregroundStyle(Clay.inkMuted)
            CredentialVerificationView(raw: raw?["document"])
        }

        Rectangle().fill(Clay.hairline).frame(height: 1)

        VStack(alignment: .leading, spacing: Clay.space3) {
            let inspected = Int(raw?["inspectedEmbeddedCount"]?.numberValue ?? 0)
            let total = Int(raw?["embeddedCount"]?.numberValue ?? 0)
            Text(total > inspected
                 ? "Embedded files · \(total) found, \(total - inspected) skipped"
                 : "Embedded files · \(total) found")
                .font(Clay.captionMedium)
                .foregroundStyle(Clay.inkMuted)
            if assets.isEmpty {
                Text("No embedded files were checked.")
                    .font(Clay.body)
                    .foregroundStyle(Clay.inkMuted)
            }
            ForEach(Array(assets.enumerated()), id: \.offset) { _, asset in
                EmbeddedAssetRow(asset: asset)
            }
            ForEach(raw?["coverageErrors"]?.arrayValue?.compactMap(\.stringValue) ?? [], id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.warning)
            }
        }

        if let scope = raw?["scope"]?.stringValue {
            Text(scope)
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EmbeddedAssetRow: View {
    let asset: JSONValue
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            CredentialVerificationView(raw: asset)
                .padding(.top, Clay.space2)
        } label: {
            HStack(spacing: Clay.space3) {
                Text(asset["path"]?.stringValue ?? "Embedded image")
                    .font(Clay.code)
                    .foregroundStyle(Clay.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Clay.space2)
                Text(WatermarkReport.credentialSummary(for: asset))
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
        }
    }
}
