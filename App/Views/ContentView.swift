import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var showingBatchExportChoices = false
    @State private var showingReplaceAllConfirmation = false
    @State private var pendingReplacementJobID: CleanerJob.ID?
    @State private var selectedDetailTab: JobDetailTab = .findings
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            QueueSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            Group {
                if let job = store.selectedJob {
                    JobDetailView(
                        store: store,
                        job: job,
                        selectedTab: $selectedDetailTab,
                        onSaveCopy: { saveCopy(job) },
                        onReplaceOriginal: { pendingReplacementJobID = job.id }
                    )
                } else {
                    EmptyQueueView(isDropTargeted: isDropTargeted, onAddFiles: addFiles)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Clay.ivory)
        }
        .navigationTitle("Provenance Cleaner")
        .navigationSubtitle(subtitle)
        .tint(Clay.accent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: addFiles) {
                    Label("Add files", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .help("Add files (⌘O)")
                .accessibilityIdentifier("toolbar.add-files")

                if store.isBusy {
                    Button {
                        Task { await store.cancelAllProcessing() }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .help("Stop checking or creating copies")
                    .accessibilityIdentifier("toolbar.stop")
                }

                Button {
                    Task { await store.createAllCopies() }
                } label: {
                    Label("Create all copies", systemImage: "square.on.square")
                        .labelStyle(.titleAndIcon)
                }
                .help("Create a copy of every file using its chosen changes")
                .disabled(!store.hasCleanableJobs || store.isBusy)
                .accessibilityIdentifier("toolbar.clean-all")

                Button {
                    showingBatchExportChoices = true
                } label: {
                    Label("Save all", systemImage: "square.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help("Save every copy that's ready")
                .disabled(!(store.hasExportableJobs || store.hasReplaceableJobs) || store.isBusy)
                .accessibilityIdentifier("toolbar.export")
            }
        }
        // The detail header lays out its own space; a toolbar backdrop over it
        // would only add a second band of colour.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.addAndInspect(urls) }
            return true
        } isTargeted: { isDropTargeted = $0 }
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
        .alert(replacementTitle, isPresented: pendingReplacementPresented) {
            Button("Replace and keep backup", role: .destructive) {
                guard let jobID = pendingReplacementJobID else { return }
                pendingReplacementJobID = nil
                Task { await store.replaceOriginal(jobID: jobID) }
            }
            Button("Cancel", role: .cancel) {
                pendingReplacementJobID = nil
            }
        } message: {
            Text(replacementMessage)
        }
        .confirmationDialog(
            "Save all copies",
            isPresented: $showingBatchExportChoices,
            titleVisibility: .visible
        ) {
            let saveCount = store.saveAllPlan().ready.count
            let replaceCount = store.replaceAllPlan().ready.count
            if saveCount > 0 {
                Button("Save \(saveCount) cop\(saveCount == 1 ? "y" : "ies") to a folder…") {
                    saveAllCopies()
                }
            }
            if replaceCount > 0 {
                Button("Replace \(replaceCount) original\(replaceCount == 1 ? "" : "s")…", role: .destructive) {
                    showingReplaceAllConfirmation = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(batchExportDisclosure)
        }
        .alert("Replace the original files?", isPresented: $showingReplaceAllConfirmation) {
            Button("Replace and keep backups", role: .destructive) {
                Task { await store.replaceAllOriginals() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each original is first copied to filename.ext.bak next to it. Existing backups are never overwritten, and an original that changed after its copy was made is left alone.")
        }
        .task {
            await store.refreshCapabilities()
        }
    }

    private var subtitle: String {
        guard !store.jobs.isEmpty else { return "" }
        let ready = store.jobs.filter { $0.canExport && !$0.isSaved && !$0.isReplaced }.count
        let files = "\(store.jobs.count) file\(store.jobs.count == 1 ? "" : "s")"
        return ready > 0 ? "\(files) · \(ready) cop\(ready == 1 ? "y" : "ies") ready" : files
    }

    private var ownershipNoticePresented: Binding<Bool> {
        Binding(
            get: { !store.preferences.acceptedOwnershipNotice },
            set: { _ in }
        )
    }

    private var pendingReplacementPresented: Binding<Bool> {
        Binding(
            get: { pendingReplacementJobID != nil },
            set: { if !$0 { pendingReplacementJobID = nil } }
        )
    }

    private var replacementJob: CleanerJob? {
        pendingReplacementJobID.flatMap { id in store.jobs.first { $0.id == id } }
    }

    private var replacementTitle: String {
        "Replace \(replacementJob?.displayName ?? "the original")?"
    }

    private var replacementMessage: String {
        var message = "The original is first copied to \(replacementJob?.displayName ?? "filename.ext").bak. An existing backup is never overwritten."
        if replacementJob?.cleaningOptions?.stripAllMetadata == true {
            message += " This copy had all removable metadata stripped, including author, dates, camera, location and copyright."
        }
        return message
    }

    private var commandActions: CleanerCommandActions {
        let selected = store.selectedJob
        return CleanerCommandActions(
            addFiles: addFiles,
            createCopy: { Task { await store.createCopyForSelected() } },
            saveCopy: { if let selected { saveCopy(selected) } },
            showTab: { selectedDetailTab = $0 },
            inspectAll: { Task { await store.inspectAll() } },
            createAllCopies: { Task { await store.createAllCopies() } },
            saveAll: { showingBatchExportChoices = true },
            removeSelected: store.removeSelected,
            canInspect: !store.jobs.isEmpty && !store.isBusy,
            canCreateCopy: selected.map(store.canCreateCopy) == true && !store.isBusy,
            canSaveCopy: selected.map(store.canSaveCopy) == true && !store.isBusy,
            canShowTabs: selected != nil,
            canCreateAllCopies: store.hasCleanableJobs && !store.isBusy,
            canSaveAll: (store.hasExportableJobs || store.hasReplaceableJobs) && !store.isBusy,
            canRemove: store.selectedJobID != nil && !store.isBusy
        )
    }

    private func addFiles() {
        let urls = FilePanelService.chooseInputs()
        guard !urls.isEmpty else { return }
        Task { await store.addAndInspect(urls) }
    }

    private func saveCopy(_ job: CleanerJob) {
        guard store.canSaveCopy(job), let destination = FilePanelService.chooseCopyDestination(for: job) else { return }
        Task { await store.saveCopy(jobID: job.id, to: destination) }
    }

    private func saveAllCopies() {
        guard let directory = FilePanelService.chooseBatchExportDirectory() else { return }
        Task { await store.saveAllCopies(to: directory) }
    }

    private var batchExportDisclosure: String {
        let save = store.saveAllPlan()
        let replace = store.replaceAllPlan()
        var parts = ["Saving copies to a folder is safest. Replacing originals keeps a .bak backup beside every file."]
        if save.outdated > 0 {
            parts.append("\(save.outdated) outdated cop\(save.outdated == 1 ? "y is" : "ies are") skipped; update \(save.outdated == 1 ? "it" : "them") first.")
        }
        if save.alreadySaved > 0 {
            parts.append("\(save.alreadySaved) already saved cop\(save.alreadySaved == 1 ? "y is" : "ies are") skipped.")
        }
        if replace.alreadyReplaced > 0 {
            parts.append("\(replace.alreadyReplaced) original\(replace.alreadyReplaced == 1 ? " was" : "s were") already replaced.")
        }
        let warnings = save.ready.filter { $0.status.tone == .warning }.count
        if warnings > 0 {
            parts.append("\(warnings) of the copies still \(warnings == 1 ? "has" : "have") markers or an unfinished check; see each file's Review tab.")
        }
        if store.jobs.contains(where: { $0.canExport && $0.cleaningOptions?.stripAllMetadata == true }) {
            parts.append("At least one copy had all removable metadata stripped, including author, dates, camera, location and copyright.")
        }
        return parts.joined(separator: " ")
    }
}
