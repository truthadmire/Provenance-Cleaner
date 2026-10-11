import SwiftUI

enum CleanerLayout { static let contentWidth: CGFloat = 980 }

/// Shared surfaces give content depth while leaving the window and sidebar native.
private struct CleanerSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0))
            }
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [.primary.opacity(colorScheme == .dark ? 0.035 : 0.015), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(contrast == .increased ? 0.3 : 0.09),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.10 : 0.025), radius: 4, y: 2)
    }
}

extension View {
    func cleanerSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(CleanerSurface(cornerRadius: cornerRadius))
    }
}

struct CleanerCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            LinearGradient(
                colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.065 : 0.035), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct CleanerSymbol: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: size * 0.27))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

struct CleanerCardHeading: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            CleanerSymbol(systemImage: systemImage, tint: tint)
            Text(title)
                .font(.headline)
        }
    }
}

extension CleanerJobStatus {
    var tint: Color {
        switch self {
        case .findings, .inspectionIncomplete, .cleanedInspectionIncomplete: .orange
        case let .readyToExport(residualCount), let .editingTracesReady(residualCount), let .metadataReady(residualCount): residualCount > 0 ? .orange : .green
        case .inspectedClean, .exported: .green
        case .failed: .red
        case .inspecting, .cleaning: .accentColor
        case .queued, .cancelled, .unsupported: .secondary
        }
    }
}
