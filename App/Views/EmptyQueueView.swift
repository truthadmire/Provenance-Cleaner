import SwiftUI

struct EmptyQueueView: View {
    var onAddFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 16) {
                CleanerSymbol(systemImage: "doc.text.magnifyingglass", size: 56)
                Text("A closer look at your files.")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                Text("Understand their origins. Edit their details.\nChoose what leaves your Mac.")
                    .font(.body).foregroundStyle(.secondary).lineSpacing(5)
            }

            VStack(spacing: 18) {
                Text("Drop files to begin").font(.headline)
                Text("Documents, images, text, audio & video")
                    .font(.caption).foregroundStyle(.secondary)
                Button(action: onAddFiles) {
                    HStack(spacing: 24) {
                        Label("Add Files…", systemImage: "plus")
                        Text("⌘O").font(.caption).opacity(0.7).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("empty-state.add-files")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }

            HStack(alignment: .top, spacing: 22) {
                feature("Inspect", detail: "Provenance & certificates", symbol: "checkmark.seal")
                feature("Refine", detail: "Author & document details", symbol: "slider.horizontal.3")
                feature("Export", detail: "A reviewed copy", symbol: "square.and.arrow.down")
            }
            Divider()
            Label("On your Mac. Originals stay untouched until export.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 540)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feature(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
