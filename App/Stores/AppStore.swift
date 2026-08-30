import Foundation
import Observation

struct AppIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppStore {
    static let maximumQueueCount = 50

    var jobs: [CleanerJob] = []
    var selectedJobID: CleanerJob.ID?
    var isCleaningSequentially = false
    var issue: AppIssue?
    var capabilities: EngineCapabilities?
    var engineAvailabilityMessage: String?
    var pendingExportJobIDs: [CleanerJob.ID] = []

    let preferences: AppPreferences

    @ObservationIgnored private let engine: any WatermarkEngine
    @ObservationIgnored private let exporter: SafeFileExporter
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let stagingRoot: URL
    @ObservationIgnored private var activeRequestIDs: [CleanerJob.ID: UUID] = [:]
    @ObservationIgnored private var cancellationRequested = false

    init(
        engine: (any WatermarkEngine)? = nil,
        preferences: AppPreferences = .shared,
        exporter: SafeFileExporter = SafeFileExporter(),
        fileManager: FileManager = .default,
        stagingRoot: URL? = nil
    ) {
        self.engine = engine ?? BundledWatermarkEngine()
        self.preferences = preferences
        self.exporter = exporter
        self.fileManager = fileManager
        self.stagingRoot = stagingRoot
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("ProvenanceCleaner", isDirectory: true)
                .appendingPathComponent("Staging", isDirectory: true)
    }

    var selectedJob: CleanerJob? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    var isBusy: Bool {
        isCleaningSequentially || jobs.contains { $0.status.isBusy }
    }

    var hasCleanableJobs: Bool {
        jobs.contains { $0.status.canClean }
    }

    var hasExportableJobs: Bool {
        jobs.contains(where: \.canExport)
    }

    var pendingExportJob: CleanerJob? {
        guard let first = pendingExportJobIDs.first else { return nil }
        return job(withID: first)
    }

    func refreshCapabilities() async {
        do {
            capabilities = try await engine.capabilities(requestID: UUID())
            engineAvailabilityMessage = nil
        } catch {
            capabilities = nil
            engineAvailabilityMessage = error.localizedDescription
        }
    }

    func addAndInspect(_ inputURLs: [URL]) async {
        cancellationRequested = false
        let expanded = SupportedFileTypes.expandInputURLs(inputURLs)
        let existingPaths = Set(jobs.map { $0.sourceURL.standardizedFileURL.path })
        var newURLs = expanded.filter { !existingPaths.contains($0.standardizedFileURL.path) }

        let remainingCapacity = max(0, Self.maximumQueueCount - jobs.count)
        if newURLs.count > remainingCapacity {
            let skipped = newURLs.count - remainingCapacity
            newURLs = Array(newURLs.prefix(remainingCapacity))
            issue = AppIssue(
                title: "Queue limit reached",
                message: "Added \(newURLs.count) items and skipped \(skipped). Provenance Cleaner processes up to \(Self.maximumQueueCount) items at a time."
            )
        }

        let newJobs = newURLs.map { url -> CleanerJob in
            var job = CleanerJob(sourceURL: url)
            job.kind = SupportedFileTypes.kind(for: url)
            if !fileManager.fileExists(atPath: url.path) {
                job.status = .failed("The file no longer exists.")
            } else if job.kind == .unknown {
                job.status = .unsupported("This file type is not supported.")
            }
            return job
        }

        jobs.append(contentsOf: newJobs)
        if selectedJobID == nil {
            selectedJobID = newJobs.first?.id
        }

        for job in newJobs where job.kind != .unknown {
            guard !Task.isCancelled, !cancellationRequested else { break }
            await inspect(jobID: job.id)
        }
    }

    func inspectSelected() async {
        guard let selectedJobID else { return }
        await inspect(jobID: selectedJobID)
    }

    func inspectAll() async {
        cancellationRequested = false
        for job in jobs where job.kind != .unknown {
            guard !Task.isCancelled, !cancellationRequested else { break }
            await inspect(jobID: job.id)
        }
    }

    func inspect(jobID: CleanerJob.ID) async {
        guard let job = job(withID: jobID), job.kind != .unknown else { return }
        update(jobID) { $0.status = .inspecting }

        do {
            let result = try await withTrackedRequest(for: jobID) { requestID in
                try await engine.inspect(fileAt: job.sourceURL, requestID: requestID)
            }
            update(jobID) { current in
                current.kind = result.kind
                current.inspection = result.report
                if result.kind == .unknown {
                    current.status = .unsupported("The engine could not classify this file.")
                } else if result.report.inspectionIncomplete {
                    current.status = .inspectionIncomplete(result.report.findings.count)
                } else if result.report.hasActionableFindings {
                    current.status = .findings(max(1, result.report.findings.count))
                } else {
                    current.status = .inspectedClean
                }
            }
        } catch where isCancellation(error) {
            update(jobID) { $0.status = .cancelled }
        } catch {
            update(jobID) { $0.status = .failed(error.localizedDescription) }
        }
    }

    func cleanSelected() async {
        guard let selectedJobID else { return }
        await clean(jobID: selectedJobID)
    }

    func cleanAllSequentially() async {
        guard !isCleaningSequentially else { return }
        cancellationRequested = false
        isCleaningSequentially = true
        defer { isCleaningSequentially = false }

        let ids = jobs.filter { $0.status.canClean }.map(\.id)
        for id in ids {
            guard !Task.isCancelled, !cancellationRequested else { break }
            await clean(jobID: id)
        }
    }

    func cancelAllProcessing() async {
        cancellationRequested = true
        let requestIDs = Array(Set(activeRequestIDs.values))
        for requestID in requestIDs {
            await engine.cancel(requestID: requestID)
        }
    }

    func clean(jobID: CleanerJob.ID) async {
        guard let job = job(withID: jobID), job.status.canClean else { return }
        let previousOutputURL = job.stagedOutputURL
        update(jobID) { $0.status = .cleaning }

        var attemptOutputURL: URL?
        do {
            let outputURL = try makeStagingURL(for: job)
            attemptOutputURL = outputURL
            let options = preferences.cleaningOptions
            let result = try await withTrackedRequest(for: jobID) { requestID in
                try await engine.clean(
                    fileAt: job.sourceURL,
                    outputURL: outputURL,
                    options: options,
                    requestID: requestID
                )
            }

            var postInspection: WatermarkReport?
            var postInspectionCompleted = true
            do {
                postInspection = try await withTrackedRequest(for: jobID) { requestID in
                    try await engine.inspect(fileAt: result.outputURL, requestID: requestID).report
                }
            } catch where isCancellation(error) {
                throw error
            } catch {
                postInspectionCompleted = false
                engineAvailabilityMessage = "Cleaned output was created, but post-clean inspection failed: \(error.localizedDescription)"
            }

            let residualCount: Int
            if let postInspection, postInspection.hasActionableFindings {
                residualCount = max(1, postInspection.findings.count)
            } else {
                residualCount = result.report.postFindings.count
            }

            update(jobID) { current in
                current.kind = result.kind
                current.cleanReport = result.report
                current.postCleanInspection = postInspection
                current.stagedOutputURL = result.outputURL
                current.cleaningOptions = options
                if !postInspectionCompleted || postInspection?.inspectionIncomplete == true {
                    current.status = .cleanedInspectionIncomplete
                } else {
                    current.status = .readyToExport(residualCount: residualCount)
                }
            }
            if let previousOutputURL, previousOutputURL != result.outputURL {
                try? fileManager.removeItem(at: previousOutputURL.deletingLastPathComponent())
            }
            if !pendingExportJobIDs.contains(jobID) {
                pendingExportJobIDs.append(jobID)
            }
        } catch where isCancellation(error) {
            if let attemptOutputURL {
                try? fileManager.removeItem(at: attemptOutputURL.deletingLastPathComponent())
            }
            update(jobID) { current in
                current.status = .cancelled
                current.stagedOutputURL = previousOutputURL
            }
        } catch {
            if let attemptOutputURL {
                try? fileManager.removeItem(at: attemptOutputURL.deletingLastPathComponent())
            }
            update(jobID) { current in
                current.status = .failed(error.localizedDescription)
                current.stagedOutputURL = previousOutputURL
            }
        }
    }

    func acknowledgePendingExport(for jobID: CleanerJob.ID) {
        pendingExportJobIDs.removeAll { $0 == jobID }
    }

    func exportSelectedCopy(to destinationURL: URL) async {
        guard let selectedJobID else {
            present(FileExportError.noStagedOutput, title: "Nothing to export")
            return
        }

        await exportCopy(jobID: selectedJobID, to: destinationURL)
    }

    func exportCopy(jobID: CleanerJob.ID, to destinationURL: URL) async {
        guard let job = job(withID: jobID), let stagedURL = job.stagedOutputURL else {
            present(FileExportError.noStagedOutput, title: "Nothing to export")
            return
        }

        do {
            let exportedURL = try await exporter.exportCopy(from: stagedURL, to: destinationURL)
            update(jobID) { $0.status = .exported(exportedURL) }
            acknowledgePendingExport(for: jobID)
        } catch {
            present(error, title: "Could not save the cleaned copy")
        }
    }

    func exportAllCopies(to directoryURL: URL) async {
        for job in jobs where job.canExport {
            guard let stagedURL = job.stagedOutputURL else { continue }
            do {
                let exportedURL = try await exporter.exportCopy(
                    from: stagedURL,
                    sourceURL: job.sourceURL,
                    into: directoryURL
                )
                update(job.id) { $0.status = .exported(exportedURL) }
            } catch {
                update(job.id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    func replaceSelectedOriginal() async {
        guard let selectedJobID else {
            present(FileExportError.noStagedOutput, title: "Nothing to replace")
            return
        }

        await replaceOriginal(jobID: selectedJobID)
    }

    func replaceOriginal(jobID: CleanerJob.ID) async {
        guard let job = job(withID: jobID), let stagedURL = job.stagedOutputURL else {
            present(FileExportError.noStagedOutput, title: "Nothing to replace")
            return
        }

        do {
            let exportedURL = try await exporter.replaceOriginal(
                from: stagedURL,
                originalURL: job.sourceURL
            )
            update(jobID) { $0.status = .exported(exportedURL) }
            acknowledgePendingExport(for: jobID)
        } catch {
            present(error, title: "Could not replace the original")
        }
    }

    func replaceAllOriginals() async {
        for job in jobs where job.canExport {
            guard let stagedURL = job.stagedOutputURL else { continue }
            do {
                let exportedURL = try await exporter.replaceOriginal(
                    from: stagedURL,
                    originalURL: job.sourceURL
                )
                update(job.id) { $0.status = .exported(exportedURL) }
            } catch {
                update(job.id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    func removeSelected() {
        guard let selectedJobID else { return }
        remove(jobIDs: [selectedJobID])
    }

    func remove(jobIDs: Set<CleanerJob.ID>) {
        let stagedURLs = jobs
            .filter { jobIDs.contains($0.id) }
            .compactMap(\.stagedOutputURL)
        jobs.removeAll { jobIDs.contains($0.id) }
        pendingExportJobIDs.removeAll { jobIDs.contains($0) }
        stagedURLs.forEach { try? fileManager.removeItem(at: $0.deletingLastPathComponent()) }
        if let selectedJobID, jobIDs.contains(selectedJobID) {
            self.selectedJobID = jobs.first?.id
        }
    }

    func clearCompleted() {
        let completed = Set(jobs.compactMap { job -> CleanerJob.ID? in
            if case .exported = job.status { return job.id }
            return nil
        })
        remove(jobIDs: completed)
    }

    private func job(withID id: CleanerJob.ID) -> CleanerJob? {
        jobs.first { $0.id == id }
    }

    private func update(_ id: CleanerJob.ID, mutate: (inout CleanerJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    private func withTrackedRequest<Result: Sendable>(
        for jobID: CleanerJob.ID,
        operation: (UUID) async throws -> Result
    ) async throws -> Result {
        let requestID = UUID()
        activeRequestIDs[jobID] = requestID
        defer {
            if activeRequestIDs[jobID] == requestID {
                activeRequestIDs[jobID] = nil
            }
        }
        return try await operation(requestID)
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? WatermarkEngineError) == .cancelled
    }

    private func makeStagingURL(for job: CleanerJob) throws -> URL {
        let directory = stagingRoot
            .appendingPathComponent(job.id.uuidString, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = job.sourceURL.pathExtension
        let filename = ext.isEmpty ? "cleaned" : "cleaned.\(ext)"
        let outputURL = directory.appendingPathComponent(filename)
        return outputURL
    }

    private func present(_ error: Error, title: String) {
        issue = AppIssue(title: title, message: error.localizedDescription)
    }
}
