import SwiftUI

struct EmptyQueueView: View {
    var onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 24) {
                documentSymbol

                VStack(spacing: 10) {
                    Text("Drop files to begin")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("Inspect provenance, review the changes,\nthen save a cleaned copy.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 14) {
                    Button(action: onAddFiles) {
                        HStack(spacing: 18) {
                            Label("Add Files…", systemImage: "plus")
                            Text("⌘O")
                                .font(.caption.weight(.medium))
                                .opacity(0.75)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("empty-state.add-files")

                    SettingsLink {
                        Text("Cleaning Settings")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Text("Text  ·  Images  ·  Documents  ·  Audio & video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
            .frame(maxWidth: 480)
            .cleanerSurface(cornerRadius: 24)

            Label("On your Mac. Originals stay untouched until export.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var documentSymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.accentColor.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 1)
                }
                .frame(width: 72, height: 84)
                .rotationEffect(.degrees(-12))
                .offset(x: -10, y: 2)

            CleanerSymbol(systemImage: "doc.text", size: 80)
                .cleanerSurface(cornerRadius: 22)
                .rotationEffect(.degrees(5))

            Image(systemName: "sparkle")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .offset(x: 46, y: -32)
        }
        .frame(height: 100)
        .accessibilityHidden(true)
    }
}
