import SwiftUI

struct EmptyQueueView: View {
    var isDropTargeted = false
    var onAddFiles: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Clay.space8) {
                VStack(alignment: .leading, spacing: Clay.space3) {
                    Text("Check your files before you share them")
                        .font(Clay.heading1)
                        .tracking(-0.3)
                        .foregroundStyle(Clay.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Provenance Cleaner finds content credentials, provenance metadata and invisible characters, then makes a cleaned copy. Your originals stay as they are until you save.")
                        .font(Clay.body)
                        .foregroundStyle(Clay.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                dropZone

                HStack(alignment: .top, spacing: Clay.space6) {
                    step(1, title: "Check", detail: "See credentials, metadata and hidden characters.")
                    step(2, title: "Choose changes", detail: "Clean, edit properties or Word editing history.")
                    step(3, title: "Review and save", detail: "Compare the copy with the original, then save.")
                }

                Rectangle().fill(Clay.hairline).frame(height: 1)

                Label("Everything stays on this Mac. The app has no network access.", systemImage: "lock")
                    .font(Clay.caption)
                    .foregroundStyle(Clay.inkMuted)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(Clay.space12)
            .frame(maxWidth: .infinity)
        }
    }

    private var dropZone: some View {
        VStack(spacing: Clay.space3) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Clay.clay)
                .accessibilityHidden(true)
            Text("Drop files here")
                .font(Clay.heading3)
                .foregroundStyle(Clay.ink)
            Text("Documents, PDFs, images, text, audio and video")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
            Button("Choose files…", action: onAddFiles)
                .buttonStyle(ClayButtonStyle(kind: .primary, isLarge: true))
                .padding(.top, Clay.space2)
                .accessibilityIdentifier("empty-state.add-files")
            Text("or press ⌘O")
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Clay.space8)
        .background(
            isDropTargeted ? Clay.claySoft : Clay.surface,
            in: RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Clay.radiusLarge, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Clay.accent : Clay.borderStrong.opacity(0.55),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 5])
                )
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Clay.space2) {
            Text("\(number)")
                .font(Clay.captionMedium)
                .foregroundStyle(Clay.accentText)
                .frame(width: 22, height: 22)
                .background(Clay.claySoft, in: Circle())
            Text(title)
                .font(Clay.bodyMedium)
                .foregroundStyle(Clay.ink)
            Text(detail)
                .font(Clay.caption)
                .foregroundStyle(Clay.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
