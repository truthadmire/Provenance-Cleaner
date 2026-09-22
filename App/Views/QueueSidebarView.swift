import SwiftUI

struct QueueSidebarView: View {
    @Bindable var store: AppStore

    var body: some View {
        List(selection: $store.selectedJobID) {
            Section {
                ForEach(store.jobs) { job in
                    QueueRow(job: job)
                        .tag(job.id)
                        .contextMenu {
                            Button("Reveal in Finder") {
                                FilePanelService.reveal(job.sourceURL)
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                store.remove(jobIDs: [job.id])
                            }
                            .disabled(job.status.isBusy)
                        }
                }
            } header: {
                HStack {
                    Text("Queue")
                    Spacer()
                    if !store.jobs.isEmpty {
                        Text(store.jobs.count, format: .number)
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.jobs.isEmpty {
                VStack(spacing: 10) {
                    CleanerSymbol(systemImage: "tray", tint: .secondary, size: 40)
                    Text("No files")
                        .font(.subheadline.weight(.medium))
                    Text("Added files will appear here")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.jobs.isEmpty {
                HStack {
                    Text("\(store.jobs.count) of \(AppStore.maximumQueueCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Exported") {
                        store.clearCompleted()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }
}

private struct QueueRow: View {
    let job: CleanerJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.kind.systemImage)
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.displayName)
                        .lineLimit(1)
                        .fontWeight(.medium)
                        .accessibilityIdentifier("queue.row.\(job.displayName)")
                    Spacer(minLength: 2)
                    Text(job.kind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier("queue.type.\(job.displayName)")
                }
                HStack(spacing: 4) {
                    if job.status.isBusy {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(job.status.label)
                        .lineLimit(1)
                        .accessibilityIdentifier("queue.status.\(job.displayName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}
