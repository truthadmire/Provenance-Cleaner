import SwiftUI

struct QueueSidebarView: View {
    @Bindable var store: AppStore

    private var hasSavedFiles: Bool {
        store.jobs.contains { $0.isSaved || $0.isReplaced }
    }

    var body: some View {
        List(selection: $store.selectedJobID) {
            Section {
                ForEach(store.jobs) { job in
                    QueueRow(job: job)
                        .tag(job.id)
                        .contextMenu {
                            Button("Show in Finder") {
                                FilePanelService.reveal(job.sourceURL)
                            }
                            Divider()
                            Button("Remove from List", role: .destructive) {
                                store.remove(jobIDs: [job.id])
                            }
                            .disabled(job.status.isBusy)
                        }
                }
            } header: {
                Text("Files")
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Clay.sunken)
        .overlay {
            if store.jobs.isEmpty {
                VStack(spacing: 6) {
                    Text("No files yet")
                        .font(Clay.label)
                        .foregroundStyle(Clay.inkMuted)
                    Text("Drop files here or press ⌘O")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !store.jobs.isEmpty {
                HStack {
                    Text("\(store.jobs.count) of \(AppStore.maximumQueueCount) files")
                        .font(Clay.caption)
                        .foregroundStyle(Clay.inkMuted)
                    Spacer()
                    Button("Remove saved") {
                        store.clearCompleted()
                    }
                    .buttonStyle(ClayLinkButtonStyle())
                    .disabled(!hasSavedFiles)
                    .opacity(hasSavedFiles ? 1 : 0.4)
                    .help("Remove files whose copies you've saved from this list")
                }
                .padding(.horizontal, Clay.space4)
                .padding(.vertical, Clay.space3)
                .background(Clay.sunken)
                .overlay(alignment: .top) {
                    Rectangle().fill(Clay.hairline).frame(height: 1)
                }
            }
        }
    }
}

private struct QueueRow: View {
    let job: CleanerJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.kind.systemImage)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("queue.row.\(job.displayName)")
                HStack(spacing: 5) {
                    if job.status.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle()
                            .fill(job.status.tone.foreground)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    Text(job.queueLabel)
                        .lineLimit(1)
                        .accessibilityIdentifier("queue.status.\(job.displayName)")
                }
                .font(Clay.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
