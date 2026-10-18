import SwiftUI

/// One asset only. An embedded image verdict must never become a document verdict.
struct CredentialVerificationView: View {
    let raw: JSONValue?
    var markersDetected = false
    private var state: String { raw?["state"]?.stringValue ?? "inconclusive" }
    private var certificates: [JSONValue] { raw?["certificates"]?.arrayValue ?? [] }
    private var statuses: [JSONValue] { raw?["statuses"]?.arrayValue ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space4) {
            if state == "present" {
                presentBody
            } else {
                HStack(alignment: .top, spacing: Clay.space3) {
                    Image(systemName: state == "absent" && !markersDetected ? "checkmark.circle" : "questionmark.circle")
                        .foregroundStyle(state == "absent" && !markersDetected ? Clay.success : Clay.warning)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stateDescription)
                            .font(Clay.body)
                            .foregroundStyle(Clay.ink)
                        if let error = raw?["error"]?.stringValue {
                            Text(error)
                                .font(Clay.caption)
                                .foregroundStyle(Clay.inkMuted)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var presentBody: some View {
        if raw?["validationFailed"]?.boolValue == true {
            ClayBanner(
                tone: .danger,
                title: "Validation failed",
                message: "The signature or content binding didn't validate. The file may have changed after it was signed."
            )
        } else if raw?["inspectionIncomplete"]?.boolValue == true {
            ClayBanner(
                tone: .warning,
                title: "Verification didn't finish",
                message: "Some of the credential couldn't be checked. Treat the results below as partial."
            )
        }

        HStack(alignment: .top, spacing: 0) {
            verdict("Signature", key: "signature")
            divider
            verdict("Content binding", key: "contentBinding")
            divider
            verdict("Certificate trust", key: "trust")
        }
        .padding(Clay.space4)
        .background(Clay.sunken, in: RoundedRectangle(cornerRadius: Clay.radiusMedium, style: .continuous))

        Grid(alignment: .leading, horizontalSpacing: Clay.space6, verticalSpacing: Clay.space2) {
            ClayKeyValueRow(key: "Signed by", value: raw?["signer"]?.stringValue)
            ClayKeyValueRow(key: "Issued by", value: raw?["issuer"]?.stringValue)
            ClayKeyValueRow(key: "Signed on", value: raw?["signedAt"]?.stringValue.map(ClayDate.display))
            ClayKeyValueRow(key: "Made with", value: raw?["generator"]?.stringValue)
            ClayKeyValueRow(key: "Algorithm", value: raw?["algorithm"]?.stringValue?.uppercased())
            ClayKeyValueRow(key: "Manifests", value: String(Int(raw?["manifestCount"]?.numberValue ?? 0)))
        }

        ClayDisclosure(title: "Certificate chain and validation details") {
            VStack(alignment: .leading, spacing: Clay.space4) {
                ForEach(Array(certificates.enumerated()), id: \.offset) { index, certificate in
                    VStack(alignment: .leading, spacing: Clay.space2) {
                        Text(index == 0 ? "Signing certificate" : "Certificate \(index + 1)")
                            .font(Clay.captionMedium)
                            .foregroundStyle(Clay.ink)
                        Grid(alignment: .leading, horizontalSpacing: Clay.space6, verticalSpacing: 6) {
                            ClayKeyValueRow(key: "Subject", value: certificate["subject"]?.stringValue)
                            ClayKeyValueRow(key: "Issuer", value: certificate["issuer"]?.stringValue)
                            ClayKeyValueRow(key: "Valid from", value: certificate["notBefore"]?.stringValue.map(ClayDate.display))
                            ClayKeyValueRow(key: "Valid until", value: certificate["notAfter"]?.stringValue.map(ClayDate.display))
                            ClayKeyValueRow(key: "Serial", value: certificate["serial"]?.stringValue, monospaced: true)
                            ClayKeyValueRow(key: "SHA-256", value: certificate["sha256"]?.stringValue, monospaced: true)
                        }
                    }
                    if index < certificates.count - 1 {
                        Rectangle().fill(Clay.hairline).frame(height: 1)
                    }
                }
                if let error = raw?["certificateError"]?.stringValue {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.warning)
                }
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    HStack(alignment: .top, spacing: Clay.space2) {
                        Image(systemName: status["category"]?.stringValue == "success" ? "checkmark.circle" : "info.circle")
                            .foregroundStyle(status["category"]?.stringValue == "success" ? Clay.success : Clay.inkMuted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status["code"]?.stringValue ?? "Validation status")
                                .font(Clay.code)
                                .foregroundStyle(Clay.ink)
                            Text(status["message"]?.stringValue ?? "")
                                .font(Clay.caption)
                                .foregroundStyle(Clay.inkMuted)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }

        if let scope = raw?["scope"]?.stringValue {
            Text(scope)
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var divider: some View {
        Rectangle().fill(Clay.hairline).frame(width: 1, height: 40).padding(.horizontal, Clay.space4)
    }

    private var stateDescription: String {
        switch state {
        case "absent": markersDetected
            ? "C2PA markers found, but no credential that can be verified"
            : "No embedded C2PA credential"
        case "present_unverified": "Credential found, but it couldn't be verified"
        case "not_applicable", "unsupported": "This format can't be verified"
        case "unavailable": "Couldn't verify: the certificate checker isn't available"
        case "inconclusive": "Couldn't verify: the check didn't finish"
        default: "Verification hasn't finished"
        }
    }

    private func verdict(_ title: String, key: String) -> some View {
        let value = raw?[key]?.stringValue ?? "unknown"
        let tone: ClayTone = switch value {
        case "valid", "trusted": .success
        case "invalid": .danger
        default: .warning
        }
        let label = [
            "valid": "Verified",
            "invalid": "Failed",
            "trusted": "Trusted locally",
            "untrusted": "Not in local trust list",
            "unknown": "Not established",
        ][value] ?? value
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
            Label(label, systemImage: tone.symbol)
                .font(Clay.label)
                .foregroundStyle(tone.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
