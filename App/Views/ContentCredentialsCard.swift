import SwiftUI

struct ContentCredentialsCard: View {
    let report: WatermarkReport
    @State private var expanded = false
    private var raw: JSONValue? { report.raw["c2pa"] }
    private var state: String { raw?["state"]?.stringValue ?? "not_applicable" }
    private var certificates: [JSONValue] { raw?["certificates"]?.arrayValue ?? [] }
    private var statuses: [JSONValue] { raw?["statuses"]?.arrayValue ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                CleanerCardHeading(title: "Content Credentials", systemImage: "checkmark.seal")
                Spacer()
                Text("C2PA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if state == "present" {
                HStack(alignment: .top, spacing: 0) {
                    verdict("Signature", key: "signature")
                    Divider().frame(height: 38).padding(.horizontal, 18)
                    verdict("Content binding", key: "contentBinding")
                    Divider().frame(height: 38).padding(.horizontal, 18)
                    verdict("Certificate trust", key: "trust")
                }
                .padding(16)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    row("Signer", value: raw?["signer"]?.stringValue)
                    row("Issuer", value: raw?["issuer"]?.stringValue)
                    row("Algorithm", value: raw?["algorithm"]?.stringValue)
                    row("Signed at", value: raw?["signedAt"]?.stringValue)
                    row("Manifests", value: String(Int(raw?["manifestCount"]?.numberValue ?? 0)))
                }
                .font(.subheadline)
                .textSelection(.enabled)
                DisclosureGroup("Certificate chain & validation details", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(certificates.enumerated()), id: \.offset) { index, certificate in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(index == 0 ? "Signing certificate" : "Certificate \(index + 1)")
                                    .font(.subheadline.weight(.semibold))
                                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                                    row("Subject", value: certificate["subject"]?.stringValue)
                                    row("Issuer", value: certificate["issuer"]?.stringValue)
                                    row("Valid from", value: certificate["notBefore"]?.stringValue)
                                    row("Valid until", value: certificate["notAfter"]?.stringValue)
                                    row("Serial", value: certificate["serial"]?.stringValue)
                                    row("SHA-256", value: certificate["sha256"]?.stringValue)
                                }
                                .font(.caption).textSelection(.enabled)
                            }
                            if index < certificates.count - 1 { Divider() }
                        }
                        if let error = raw?["certificateError"]?.stringValue {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: status["category"]?.stringValue == "success" ? "checkmark.circle" : "info.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(status["code"]?.stringValue ?? "Validation status").fontWeight(.medium)
                                    Text(status["message"]?.stringValue ?? "").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 14)
                }
                .font(.caption)
                Text(raw?["scope"]?.stringValue ?? "Offline verification only.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label(stateDescription, systemImage: state == "absent" ? "doc.badge.magnifyingglass" : "info.circle")
                    .foregroundStyle(.secondary)
                if let error = raw?["error"]?.stringValue {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(raw?["scope"]?.stringValue ?? "A marker or manifest alone does not prove who created a file or whether its content is true.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24).cleanerSurface()
        .accessibilityIdentifier("credentials.card")
    }

    private var stateDescription: String {
        switch state {
        case "absent": report.raw["has_c2pa"]?.boolValue == true
            ? "C2PA markers detected; no verifiable manifest found"
            : "No embedded C2PA manifest found"
        case "not_applicable": "C2PA verification does not apply to this container format"
        case "unsupported": "Certificate verification is not supported for this format"
        case "unavailable": "Certificate verifier unavailable"
        case "inconclusive": "C2PA inspection could not be completed"
        default: "No certificate verification is available for this file type"
        }
    }

    private func verdict(_ title: String, key: String) -> some View {
        let value = raw?[key]?.stringValue ?? "unknown"
        let good = value == "valid" || value == "trusted"
        let label = ["valid": "Verified", "invalid": "Failed", "trusted": "Trusted locally", "untrusted": "Not trusted", "unknown": "Not established"][value] ?? value
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Label(label, systemImage: good ? "checkmark.circle.fill" : "questionmark.circle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(good ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, value: String?) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "Not provided")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
