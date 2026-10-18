import SwiftUI

struct OwnershipNoticeView: View {
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Clay.space6) {
            VStack(alignment: .leading, spacing: Clay.space2) {
                Text("Before you start")
                    .font(Clay.heading2)
                    .foregroundStyle(Clay.ink)
                Text("Provenance Cleaner changes file metadata and removes invisible text characters.")
                    .font(Clay.body)
                    .foregroundStyle(Clay.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Clay.space4) {
                NoticePoint(
                    systemImage: "person.crop.circle.badge.checkmark",
                    title: "Use files you're allowed to change",
                    message: "Only process files you own or have permission to modify."
                )
                NoticePoint(
                    systemImage: "eye",
                    title: "Review every copy",
                    message: "Cleaning can remove information other people or tools rely on. Your originals stay as they are until you save."
                )
                NoticePoint(
                    systemImage: "checkmark.seal",
                    title: "No guarantee",
                    message: "A clean report covers only the checks that ran. It doesn't prove that every possible watermark is gone."
                )
            }
            .clayCard()

            HStack {
                Spacer()
                Button("I understand, continue", action: onAccept)
                    .buttonStyle(ClayButtonStyle(kind: .primary, isLarge: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Clay.space8)
        .frame(width: 560)
        .background(Clay.ivory)
        .tint(Clay.accent)
    }
}

private struct NoticePoint: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Clay.space3) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Clay.inkMuted)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Clay.bodyMedium)
                    .foregroundStyle(Clay.ink)
                Text(message)
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
