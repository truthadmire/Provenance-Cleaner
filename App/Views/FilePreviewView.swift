import AppKit
import QuickLookUI
import SwiftUI

struct FilePreviewView: View {
    let job: CleanerJob

    var body: some View {
        Group {
            switch job.kind {
            case .text:
                TextComparisonPreview(
                    originalURL: job.sourceURL,
                    cleanedURL: job.stagedOutputURL,
                    reloadToken: job.status.label
                )
            case .image:
                ImageComparisonPreview(originalURL: job.sourceURL, cleanedURL: job.stagedOutputURL)
            case .container, .av, .unknown:
                QuickLookComparisonPreview(originalURL: job.sourceURL, cleanedURL: job.stagedOutputURL)
            }
        }
        .padding(20)
    }
}

private struct TextComparisonPreview: View {
    let originalURL: URL
    let cleanedURL: URL?
    let reloadToken: String

    @State private var loadState = TextComparisonLoadState.loading

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Preparing text preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .original(document):
                VStack(alignment: .leading, spacing: 10) {
                    if document.wasTruncated {
                        previewLimitLabel
                    }
                    PreviewPane(title: "Original") {
                        textPane([TextDiffSegment(text: document.text, kind: .unchanged)])
                    }
                }
            case let .comparison(diff):
                VStack(alignment: .leading, spacing: 10) {
                    diffSummary(diff)
                    HStack(spacing: 12) {
                        PreviewPane(title: "Original") {
                            textPane(diff.originalSegments)
                        }

                        PreviewPane(title: "Cleaned") {
                            textPane(diff.cleanedSegments)
                        }
                    }
                }
            case let .failed(message):
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(message)
                )
            }
        }
        .task(id: taskIdentity) {
            await loadPreview()
        }
    }

    private var taskIdentity: String {
        [originalURL.path, cleanedURL?.path ?? "", reloadToken].joined(separator: "\n")
    }

    private var previewLimitLabel: some View {
        Label(
            "Preview limited to the first \(Int64(TextPreviewLoader.maximumBytes).formatted(.byteCount(style: .file)))",
            systemImage: "text.badge.ellipsis"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func diffSummary(_ diff: TextDiffResult) -> some View {
        HStack(spacing: 14) {
            if diff.hasChanges {
                Label(
                    TextDiffSummary.removedLabel(for: diff.removedCodePointCount),
                    systemImage: "minus.circle.fill"
                )
                .foregroundStyle(.red)

                Label(
                    TextDiffSummary.insertedLabel(for: diff.insertedCodePointCount),
                    systemImage: "plus.circle.fill"
                )
                .foregroundStyle(.green)
            } else {
                Label(
                    diff.wasTruncated
                        ? "No differences in compared prefix"
                        : "No text differences",
                    systemImage: "checkmark.circle.fill"
                )
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if diff.wasTruncated || diff.usedSimplifiedDiff {
                Label(diffLimitLabel(for: diff), systemImage: "text.badge.ellipsis")
                    .foregroundStyle(.secondary)
                    .help(diffLimitHelp(for: diff))
            }
        }
        .font(.caption.weight(.medium))
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func diffLimitLabel(for diff: TextDiffResult) -> String {
        switch (diff.wasTruncated, diff.usedSimplifiedDiff) {
        case (true, true): "Partial block comparison"
        case (true, false): "Partial comparison"
        case (false, true): "Large change shown as blocks"
        case (false, false): ""
        }
    }

    private func diffLimitHelp(for diff: TextDiffResult) -> String {
        var parts: [String] = []
        if diff.usedSimplifiedDiff {
            parts.append(
                "To keep the preview responsive, a large changed region is shown as removed and inserted blocks instead of a minimal edit. Counts describe the displayed blocks."
            )
        }
        if diff.wasTruncated {
            parts.append(
                "Counts cover the displayed comparison. Each side is limited to "
                    + "\(TextDiffLimits.preview.maximumVisibleCodePointsPerSide.formatted()) Unicode code points, "
                    + "with at most \(TextDiffLimits.preview.maximumChangedCodePointsPerSide.formatted()) "
                    + "code points from a large changed region."
            )
        }
        return parts.joined(separator: " ")
    }

    private func textPane(_ segments: [TextDiffSegment]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(attributedText(for: segments))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        }
        .background(.background)
    }

    private func attributedText(for segments: [TextDiffSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var run = AttributedString(revealedText(for: segment))
            switch segment.kind {
            case .unchanged:
                break
            case .removed:
                run.foregroundColor = .red
                run.backgroundColor = .red.opacity(0.16)
            case .inserted:
                run.foregroundColor = .green
                run.backgroundColor = .green.opacity(0.16)
            }
            result.append(run)
        }
        return result
    }

    private func revealedText(for segment: TextDiffSegment) -> String {
        guard segment.kind != .unchanged else { return segment.text }
        var result = ""
        for scalar in segment.text.unicodeScalars {
            switch scalar.value {
            case 0x00AD, 0x034F, 0x061C, 0x180E,
                 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F,
                 0xFE00...0xFE0F, 0xFEFF, 0xE0100...0xE01EF:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "⟦U+\(String(repeating: "0", count: max(0, 4 - hex.count)))\(hex)⟧"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    @MainActor
    private func loadPreview() async {
        loadState = .loading

        guard let cleanedURL else {
            let original = await TextPreviewLoader.load(originalURL)
            guard !Task.isCancelled else { return }
            if let errorDescription = original.errorDescription {
                loadState = .failed(errorDescription)
            } else {
                loadState = .original(original)
            }
            return
        }

        async let originalTask = TextPreviewLoader.load(originalURL)
        async let cleanedTask = TextPreviewLoader.load(cleanedURL)
        let (original, cleaned) = await (originalTask, cleanedTask)
        guard !Task.isCancelled else { return }

        if let errorDescription = original.errorDescription {
            loadState = .failed("Original: \(errorDescription)")
            return
        }
        if let errorDescription = cleaned.errorDescription {
            loadState = .failed("Cleaned: \(errorDescription)")
            return
        }

        let comparison = await Task.detached(priority: .utility) {
            TextDiffEngine.compare(
                original: original.text,
                cleaned: cleaned.text,
                sourceWasTruncated: original.wasTruncated || cleaned.wasTruncated
            )
        }.value
        guard !Task.isCancelled else { return }
        loadState = .comparison(comparison)
    }
}

private struct ImageComparisonPreview: View {
    let originalURL: URL
    let cleanedURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            PreviewPane(title: "Original") {
                image(at: originalURL)
            }

            if let cleanedURL {
                PreviewPane(title: "Cleaned") {
                    image(at: cleanedURL)
                }
            }
        }
    }

    @ViewBuilder
    private func image(at url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(12)
        } else {
            ContentUnavailableView("Preview unavailable", systemImage: "photo.badge.exclamationmark")
        }
    }
}

private struct QuickLookComparisonPreview: View {
    let originalURL: URL
    let cleanedURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            PreviewPane(title: "Original") {
                QuickLookPreview(url: originalURL)
            }

            if let cleanedURL {
                PreviewPane(title: "Cleaned") {
                    QuickLookPreview(url: cleanedURL)
                }
            }
        }
    }
}

private struct PreviewPane<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityIdentifier("preview.pane.\(title.lowercased())")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.separator.opacity(0.7), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            preconditionFailure("Quick Look could not create a preview view")
        }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}

private enum TextPreviewLoader {
    static let maximumBytes = 256 << 10

    static func load(_ url: URL) async -> TextPreviewDocument {
        await Task.detached(priority: .utility) {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                let truncated = data.count > maximumBytes
                let visibleData = Data(data.prefix(maximumBytes))
                let body = UTF8PreviewDecoder.decode(
                    visibleData,
                    trimmingIncompleteTrailingSequence: truncated
                )
                return TextPreviewDocument(
                    text: body,
                    wasTruncated: truncated,
                    errorDescription: nil
                )
            } catch {
                return TextPreviewDocument(
                    text: "",
                    wasTruncated: false,
                    errorDescription: error.localizedDescription
                )
            }
        }.value
    }
}

enum UTF8PreviewDecoder {
    static func decode(
        _ data: Data,
        trimmingIncompleteTrailingSequence: Bool
    ) -> String {
        guard trimmingIncompleteTrailingSequence else {
            return String(decoding: data, as: UTF8.self)
        }

        let trailingByteCount = incompleteTrailingSequenceByteCount(in: data)
        guard trailingByteCount > 0 else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: data.dropLast(trailingByteCount), as: UTF8.self)
    }

    private static func incompleteTrailingSequenceByteCount(in data: Data) -> Int {
        let tail = Array(data.suffix(4))
        guard !tail.isEmpty else { return 0 }

        var leadIndex = tail.count - 1
        while leadIndex >= 0, tail[leadIndex] & 0xC0 == 0x80 {
            leadIndex -= 1
        }
        guard leadIndex >= 0 else { return 0 }

        let leadByte = tail[leadIndex]
        let expectedByteCount: Int
        switch leadByte {
        case 0xC2...0xDF:
            expectedByteCount = 2
        case 0xE0...0xEF:
            expectedByteCount = 3
        case 0xF0...0xF4:
            expectedByteCount = 4
        default:
            return 0
        }

        let availableByteCount = tail.count - leadIndex
        return availableByteCount < expectedByteCount ? availableByteCount : 0
    }
}

private struct TextPreviewDocument: Sendable {
    let text: String
    let wasTruncated: Bool
    let errorDescription: String?
}

private enum TextComparisonLoadState {
    case loading
    case original(TextPreviewDocument)
    case comparison(TextDiffResult)
    case failed(String)
}

struct TextDiffLimits: Equatable, Sendable {
    let maximumVisibleCodePointsPerSide: Int
    let maximumChangedCodePointsPerSide: Int
    let maximumDetailedComparisonWork: Int

    static let preview = TextDiffLimits(
        maximumVisibleCodePointsPerSide: 64 << 10,
        maximumChangedCodePointsPerSide: 4_000,
        maximumDetailedComparisonWork: 4_000_000
    )

    init(
        maximumVisibleCodePointsPerSide: Int,
        maximumChangedCodePointsPerSide: Int,
        maximumDetailedComparisonWork: Int = 4_000_000
    ) {
        precondition(maximumVisibleCodePointsPerSide > 0)
        precondition(maximumChangedCodePointsPerSide > 0)
        precondition(maximumDetailedComparisonWork > 0)
        self.maximumVisibleCodePointsPerSide = maximumVisibleCodePointsPerSide
        self.maximumChangedCodePointsPerSide = maximumChangedCodePointsPerSide
        self.maximumDetailedComparisonWork = maximumDetailedComparisonWork
    }
}

struct TextDiffSegment: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unchanged
        case removed
        case inserted
    }

    let text: String
    let kind: Kind
}

struct TextDiffResult: Equatable, Sendable {
    let originalSegments: [TextDiffSegment]
    let cleanedSegments: [TextDiffSegment]
    let removedCodePointCount: Int
    let insertedCodePointCount: Int
    let wasTruncated: Bool
    let usedSimplifiedDiff: Bool

    var hasChanges: Bool {
        removedCodePointCount > 0 || insertedCodePointCount > 0
    }

    var originalVisibleText: String {
        originalSegments.map(\.text).joined()
    }

    var cleanedVisibleText: String {
        cleanedSegments.map(\.text).joined()
    }
}

enum TextDiffEngine {
    static func compare(
        original: String,
        cleaned: String,
        sourceWasTruncated: Bool = false,
        limits: TextDiffLimits = .preview
    ) -> TextDiffResult {
        let originalWindow = boundedScalars(
            original,
            limit: limits.maximumVisibleCodePointsPerSide
        )
        let cleanedWindow = boundedScalars(
            cleaned,
            limit: limits.maximumVisibleCodePointsPerSide
        )
        let originalScalars = originalWindow.scalars
        let cleanedScalars = cleanedWindow.scalars

        var commonPrefixCount = 0
        let maximumPrefixCount = min(originalScalars.count, cleanedScalars.count)
        while commonPrefixCount < maximumPrefixCount,
              originalScalars[commonPrefixCount] == cleanedScalars[commonPrefixCount] {
            commonPrefixCount += 1
        }

        var commonSuffixCount = 0
        let maximumSuffixCount = min(
            originalScalars.count - commonPrefixCount,
            cleanedScalars.count - commonPrefixCount
        )
        while commonSuffixCount < maximumSuffixCount,
              originalScalars[originalScalars.count - commonSuffixCount - 1]
                == cleanedScalars[cleanedScalars.count - commonSuffixCount - 1] {
            commonSuffixCount += 1
        }

        let originalMiddleEnd = originalScalars.count - commonSuffixCount
        let cleanedMiddleEnd = cleanedScalars.count - commonSuffixCount
        let originalMiddle = originalScalars[commonPrefixCount..<originalMiddleEnd]
        let cleanedMiddle = cleanedScalars[commonPrefixCount..<cleanedMiddleEnd]
        let changedRegionWasTruncated =
            originalMiddle.count > limits.maximumChangedCodePointsPerSide
            || cleanedMiddle.count > limits.maximumChangedCodePointsPerSide
        let comparableOriginalMiddle = Array(
            originalMiddle.prefix(limits.maximumChangedCodePointsPerSide)
        )
        let comparableCleanedMiddle = Array(
            cleanedMiddle.prefix(limits.maximumChangedCodePointsPerSide)
        )

        var removedMiddleOffsets = Set<Int>()
        var insertedMiddleOffsets = Set<Int>()
        let usesDetailedDiff = shouldUseDetailedDiff(
            originalCount: comparableOriginalMiddle.count,
            cleanedCount: comparableCleanedMiddle.count,
            maximumWork: limits.maximumDetailedComparisonWork
        )
        if usesDetailedDiff {
            let difference = comparableCleanedMiddle.difference(from: comparableOriginalMiddle)
            for change in difference {
                switch change {
                case let .remove(offset, _, _):
                    removedMiddleOffsets.insert(offset)
                case let .insert(offset, _, _):
                    insertedMiddleOffsets.insert(offset)
                }
            }
        } else {
            removedMiddleOffsets = Set(comparableOriginalMiddle.indices)
            insertedMiddleOffsets = Set(comparableCleanedMiddle.indices)
        }

        let originalPrefix = Array(originalScalars.prefix(commonPrefixCount))
        let cleanedPrefix = Array(cleanedScalars.prefix(commonPrefixCount))
        let originalSuffix = changedRegionWasTruncated
            ? []
            : Array(originalScalars.suffix(commonSuffixCount))
        let cleanedSuffix = changedRegionWasTruncated
            ? []
            : Array(cleanedScalars.suffix(commonSuffixCount))
        let visibleOriginal = originalPrefix + comparableOriginalMiddle + originalSuffix
        let visibleCleaned = cleanedPrefix + comparableCleanedMiddle + cleanedSuffix
        let removedOffsets = Set(
            removedMiddleOffsets.map { commonPrefixCount + $0 }
        )
        let insertedOffsets = Set(
            insertedMiddleOffsets.map { commonPrefixCount + $0 }
        )

        return TextDiffResult(
            originalSegments: segments(
                from: visibleOriginal,
                changedOffsets: removedOffsets,
                changedKind: .removed
            ),
            cleanedSegments: segments(
                from: visibleCleaned,
                changedOffsets: insertedOffsets,
                changedKind: .inserted
            ),
            removedCodePointCount: removedOffsets.count,
            insertedCodePointCount: insertedOffsets.count,
            wasTruncated: sourceWasTruncated
                || originalWindow.wasTruncated
                || cleanedWindow.wasTruncated
                || changedRegionWasTruncated,
            usedSimplifiedDiff: !usesDetailedDiff
        )
    }

    private static func shouldUseDetailedDiff(
        originalCount: Int,
        cleanedCount: Int,
        maximumWork: Int
    ) -> Bool {
        originalCount == 0
            || cleanedCount == 0
            || cleanedCount <= maximumWork / originalCount
    }

    private static func boundedScalars(
        _ text: String,
        limit: Int
    ) -> (scalars: [Unicode.Scalar], wasTruncated: Bool) {
        let candidate = Array(text.unicodeScalars.prefix(limit + 1))
        guard candidate.count > limit else {
            return (candidate, false)
        }
        return (Array(candidate.prefix(limit)), true)
    }

    private static func segments(
        from scalars: [Unicode.Scalar],
        changedOffsets: Set<Int>,
        changedKind: TextDiffSegment.Kind
    ) -> [TextDiffSegment] {
        guard !scalars.isEmpty else { return [] }

        var result: [TextDiffSegment] = []
        var buffer = ""
        var currentKind: TextDiffSegment.Kind = changedOffsets.contains(0)
            ? changedKind
            : .unchanged

        for (offset, scalar) in scalars.enumerated() {
            let kind: TextDiffSegment.Kind = changedOffsets.contains(offset)
                ? changedKind
                : .unchanged
            if kind != currentKind {
                result.append(TextDiffSegment(text: buffer, kind: currentKind))
                buffer = ""
                currentKind = kind
            }
            buffer.unicodeScalars.append(scalar)
        }
        result.append(TextDiffSegment(text: buffer, kind: currentKind))
        return result
    }
}

enum TextDiffSummary {
    static func removedLabel(for count: Int) -> String {
        "\(count.formatted()) code point\(count == 1 ? "" : "s") removed"
    }

    static func insertedLabel(for count: Int) -> String {
        "\(count.formatted()) code point\(count == 1 ? "" : "s") inserted"
    }
}
