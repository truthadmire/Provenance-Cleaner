import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var showingBatchExportChoices = false
    @State private var showingReplaceAllConfirmation = false
    @State private var pendingReplacementJobID: CleanerJob.ID?
    @State private var selectedDetailTab: JobDetailTab = .overview

    var body: some View {
        NavigationSplitView {
            QueueSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 245, ideal: 285, max: 360)
        } detail: {
            Group {
                if let job = store.selectedJob {
                    JobDetailView(
                        job: job,
                        preferences: store.preferences,
                        isBatchBusy: store.isCleaningSequentially,
                        selectedTab: $selectedDetailTab,
                        onInspect: { Task { await store.inspect(jobID: job.id) } },
                        onClean: { Task { await store.clean(jobID: job.id) } },
                        onExportCopy: { exportSelectedCopy(job) },
                        onReplaceOriginal: { Task { await store.replaceSelectedOriginal() } },
                        onReveal: { FilePanelService.reveal(job.sourceURL) }
                    )
                } else {
                    EmptyQueueView(onAddFiles: addFiles)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: addFiles) {
                    Label("Add Files", systemImage: "plus")
                }
                .help("Add files")
                .accessibilityIdentifier("toolbar.add-files")

                Button {
                    Task { await store.inspectAll() }
                } label: {
                    Label("Inspect All", systemImage: "magnifyingglass")
                }
                .disabled(store.jobs.isEmpty || store.isBusy)
                .accessibilityIdentifier("toolbar.inspect-all")

                Button {
                    Task { await store.cleanAllSequentially() }
                } label: {
                    Label("Clean All", systemImage: "wand.and.stars")
                }
                .disabled(!store.hasCleanableJobs || store.isBusy)
                .accessibilityIdentifier("toolbar.clean-all")

                if store.isBusy {
                    Button {
                        Task { await store.cancelAllProcessing() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Stop the current inspection or cleaning operation")
                    .accessibilityIdentifier("toolbar.stop")
                }

                Button {
                    showingBatchExportChoices = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .disabled(!store.hasExportableJobs || store.isBusy)
                .accessibilityIdentifier("toolbar.export")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.addAndInspect(urls) }
            return true
        }
        .focusedSceneValue(\.cleanerCommandActions, commandActions)
        .sheet(isPresented: ownershipNoticePresented) {
            OwnershipNoticeView {
                store.preferences.acceptOwnershipNotice()
            }
            .interactiveDismissDisabled()
        }
        .alert(item: $store.issue) { issue in
            Alert(
                title: Text(issue.title),
                message: Text(issue.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            "Review and export \(store.pendingExportJob?.displayName ?? "cleaned file")",
            isPresented: pendingJobExportPresented,
            titleVisibility: .visible
        ) {
            if let job = store.pendingExportJob {
                Button("Save Cleaned Copy…") {
                    store.acknowledgePendingExport(for: job.id)
                    guard let destination = FilePanelService.chooseCopyDestination(for: job) else { return }
                    Task { await store.exportCopy(jobID: job.id, to: destination) }
                }
                Button("Replace Original and Keep .bak", role: .destructive) {
                    store.acknowledgePendingExport(for: job.id)
                    pendingReplacementJobID = job.id
                }
                Button("Review Before Export") {
                    store.selectedJobID = job.id
                    selectedDetailTab = .overview
                    store.acknowledgePendingExport(for: job.id)
                }
                Button("Not Now", role: .cancel) {
                    store.acknowledgePendingExport(for: job.id)
                }
            }
        } message: {
            Text(exportDisclosure(for: store.pendingExportJob))
        }
        .alert("Replace original file?", isPresented: pendingReplacementPresented) {
            Button("Replace and Keep Backup", role: .destructive) {
                guard let jobID = pendingReplacementJobID else { return }
                pendingReplacementJobID = nil
                Task { await store.replaceOriginal(jobID: jobID) }
            }
            Button("Cancel", role: .cancel) {
                pendingReplacementJobID = nil
            }
        } message: {
            Text("The original is copied to filename.ext.bak before the cleaned file is installed. Existing backups are never overwritten.")
        }
        .confirmationDialog(
            "Export cleaned files",
            isPresented: $showingBatchExportChoices,
            titleVisibility: .visible
        ) {
            Button("Save Cleaned Copies…") {
                exportAllCopies()
            }
            Button("Replace Originals and Keep .bak", role: .destructive) {
                showingReplaceAllConfirmation = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(batchExportDisclosure)
        }
        .alert("Replace original files?", isPresented: $showingReplaceAllConfirmation) {
            Button("Replace and Keep Backups", role: .destructive) {
                Task { await store.replaceAllOriginals() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each original will be copied to filename.ext.bak before replacement. Existing backups are never overwritten.")
        }
        .task {
            await store.refreshCapabilities()
        }
    }

    private var ownershipNoticePresented: Binding<Bool> {
        Binding(
            get: { !store.preferences.acceptedOwnershipNotice },
            set: { _ in }
        )
    }

    private var pendingJobExportPresented: Binding<Bool> {
        Binding(
            get: { store.pendingExportJob != nil },
            set: { presented in
                if !presented, let jobID = store.pendingExportJob?.id {
                    store.acknowledgePendingExport(for: jobID)
                }
            }
        )
    }

    private var pendingReplacementPresented: Binding<Bool> {
        Binding(
            get: { pendingReplacementJobID != nil },
            set: { if !$0 { pendingReplacementJobID = nil } }
        )
    }

    private var commandActions: CleanerCommandActions {
        CleanerCommandActions(
            addFiles: addFiles,
            cleanSelected: { Task { await store.cleanSelected() } },
            exportSelected: exportSelectedCopy,
            quickLook: { selectedDetailTab = .preview },
            inspectAll: { Task { await store.inspectAll() } },
            cleanAll: { Task { await store.cleanAllSequentially() } },
            exportAll: { showingBatchExportChoices = true },
            removeSelected: store.removeSelected,
            canInspect: !store.jobs.isEmpty && !store.isBusy,
            canCleanSelected: store.selectedJob?.status.canClean == true && !store.isBusy,
            canExportSelected: store.selectedJob?.canExport == true && !store.isBusy,
            canQuickLook: store.selectedJob != nil,
            canCleanAll: store.hasCleanableJobs && !store.isBusy,
            canExportAll: store.hasExportableJobs && !store.isBusy,
            canRemove: store.selectedJobID != nil && !store.isBusy
        )
    }

    private func addFiles() {
        let urls = FilePanelService.chooseInputs()
        guard !urls.isEmpty else { return }
        Task { await store.addAndInspect(urls) }
    }

    private func exportSelectedCopy(_ job: CleanerJob) {
        guard let destination = FilePanelService.chooseCopyDestination(for: job) else { return }
        Task { await store.exportSelectedCopy(to: destination) }
    }

    private func exportSelectedCopy() {
        guard let job = store.selectedJob, job.canExport else { return }
        exportSelectedCopy(job)
    }

    private func exportAllCopies() {
        guard let directory = FilePanelService.chooseBatchExportDirectory() else { return }
        Task { await store.exportAllCopies(to: directory) }
    }

    private func exportDisclosure(for job: CleanerJob?) -> String {
        var message = "The original is unchanged. Saving a cleaned copy is safest; replacement is atomic and keeps a recoverable no-clobber .bak backup."
        if job?.cleaningOptions?.stripAllMetadata == true {
            message += " This result used Strip All Metadata: ordinary author, date, camera, location, copyright, and descriptive fields may also have been removed."
        }
        return message
    }

    private var batchExportDisclosure: String {
        var message = "Saving copies is safest. Replacing originals first creates a no-clobber .bak beside every file."
        if store.jobs.contains(where: { $0.canExport && $0.cleaningOptions?.stripAllMetadata == true }) {
            message += " At least one result used Strip All Metadata, so ordinary author, date, camera, location, copyright, and descriptive fields may also have been removed."
        }
        return message
    }
}

private struct EmptyQueueView: View {
    var onAddFiles: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Drop files to begin", systemImage: "square.and.arrow.down.on.square")
        } description: {
            Text("Inspect first, review exact findings, then create cleaned copies without sending content off this Mac.")
        } actions: {
            Button("Add Files…", action: onAddFiles)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("empty-state.add-files")
            SettingsLink {
                Text("Cleaning Settings")
            }
        }
    }
}
