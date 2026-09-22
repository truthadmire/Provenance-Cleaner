import SwiftUI

struct OwnershipNoticeView: View {
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                CleanerSymbol(systemImage: "hand.raised", size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use content responsibly")
                        .font(.title2.weight(.semibold))
                    Text("Provenance Cleaner modifies file metadata and invisible text characters.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                NoticePoint(
                    systemImage: "person.crop.circle.badge.checkmark",
                    title: "Process only authorized content",
                    message: "Use this app only with files you own or have permission to modify."
                )
                NoticePoint(
                    systemImage: "doc.badge.ellipsis",
                    title: "Review every result",
                    message: "Cleaning can remove provenance or metadata that another workflow relies on. Originals are preserved by default."
                )
                NoticePoint(
                    systemImage: "checkmark.seal",
                    title: "No universal guarantee",
                    message: "A clean report covers the checks that were available; it does not certify that every possible watermark is gone."
                )
            }
            .padding(20)
            .cleanerSurface()

            Button("I Understand and Want to Continue", action: onAccept)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(28)
        .frame(width: 590)
        .background { CleanerCanvas() }
    }
}

private struct NoticePoint: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
