import SwiftUI

struct QueueSidebarView: View {
    @Bindable var store: AppStore

    var body: some View {
        List(selection: $store.selectedJobID) {
            Section("Queue") {
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
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if store.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                    Text("No files")
                        .font(.headline)
                    Text("Drop files into the window")
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
                .padding(.vertical, 8)
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
                .foregroundStyle(.secondary)
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 2) {
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
                    } else {
                        Image(systemName: job.status.systemImage)
                    }
                    Text(job.status.label)
                        .lineLimit(1)
                        .accessibilityIdentifier("queue.status.\(job.displayName)")
                }
                .font(.caption)
                .foregroundStyle(statusStyle)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusStyle: HierarchicalShapeStyle {
        switch job.status {
        case .failed, .unsupported:
            .secondary
        default:
            .secondary
        }
    }
}
