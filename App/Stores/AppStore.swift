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
        jobs.contains { canCreateCopy($0) }
    }

    var hasExportableJobs: Bool {
        jobs.contains(where: \.canExport)
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
                message: "Added \(newURLs.count) and skipped \(skipped). Provenance Cleaner works on up to \(Self.maximumQueueCount) files at a time."
            )
        }

        let newJobs = newURLs.map { url -> CleanerJob in
            var job = CleanerJob(sourceURL: url)
            job.kind = SupportedFileTypes.kind(for: url)
            if !fileManager.fileExists(atPath: url.path) {
                job.status = .failed("The file no longer exists.")
            } else if job.kind == .unknown {
                job.status = .unsupported("This file type isn't supported.")
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

    /// Re-checks the original and, when a copy exists, the copy as well. The
    /// two reports stay separate so an original's verdict never describes a copy.
    func inspect(jobID: CleanerJob.ID) async {
        guard let job = job(withID: jobID), job.kind != .unknown else { return }
        update(jobID) { $0.status = .inspecting }

        do {
            let original = try await withTrackedRequest(for: jobID) { requestID in
                try await engine.inspect(fileAt: job.sourceURL, requestID: requestID)
            }
            update(jobID) { current in
                current.kind = original.kind
                current.inspection = original.report
            }
            guard let stagedURL = job.stagedOutputURL else {
                update(jobID) { $0.status = Self.inspectionStatus(kind: original.kind, report: original.report) }
                return
            }
            let copy = try await withTrackedRequest(for: jobID) { requestID in
                try await engine.inspect(fileAt: stagedURL, requestID: requestID)
            }
            update(jobID) { current in
                current.postCleanInspection = copy.report
                current.status = Self.resultStatus(
                    postInspection: copy.report,
                    postInspectionCompleted: true,
                    cleanReport: current.cleanReport
                )
            }
        } catch where isCancellation(error) {
            update(jobID) { $0.status = .cancelled }
        } catch {
            update(jobID) { $0.status = .failed(error.localizedDescription) }
        }
    }

    func updatePlan(for jobID: CleanerJob.ID, _ mutate: (inout JobPlan) -> Void) {
        update(jobID) { mutate(&$0.plan) }
    }

    func createCopyForSelected() async {
        guard let selectedJobID else { return }
        await createCopy(jobID: selectedJobID)
    }

    func createAllCopies() async {
        guard !isCleaningSequentially else { return }
        cancellationRequested = false
        isCleaningSequentially = true
        defer { isCleaningSequentially = false }

        let ids = jobs.filter(canCreateCopy).map(\.id)
        for id in ids {
            guard !Task.isCancelled, !cancellationRequested else { break }
            await createCopy(jobID: id)
        }
    }

    func cancelAllProcessing() async {
        cancellationRequested = true
        let requestIDs = Array(Set(activeRequestIDs.values))
        for requestID in requestIDs {
            await engine.cancel(requestID: requestID)
        }
    }

    /// The engine steps a plan needs, in the fixed order they run.
    func buildSteps(for job: CleanerJob) -> [(kind: BuildStepKind, options: CleaningOptions)] {
        var steps: [(kind: BuildStepKind, options: CleaningOptions)] = []
        if job.plan.removeProvenance {
            steps.append((.provenance, preferences.cleaningOptions))
        }
        if job.plan.changeWordTraces, job.isWordDocument {
            var options = CleaningOptions.conservative
            options.wordTraces = preferences.wordTraceOptions
            steps.append((.wordTraces, options))
        }
        if !job.plan.propertyEdits.isEmpty {
            var options = CleaningOptions.conservative
            options.metadataEdits = job.plan.propertyEdits
            steps.append((.properties, options))
        }
        return steps
    }

    /// The copy no longer reflects the file's plan or the cleaning settings.
    func copyNeedsUpdate(_ job: CleanerJob) -> Bool {
        guard job.stagedOutputURL != nil, let appliedPlan = job.appliedPlan else { return false }
        if appliedPlan != job.plan { return true }
        if job.plan.removeProvenance, job.cleaningOptions != preferences.cleaningOptions { return true }
        if job.plan.changeWordTraces, job.isWordDocument,
           job.stepResult(.wordTraces)?.options.wordTraces != preferences.wordTraceOptions {
            return true
        }
        return false
    }

    func canCreateCopy(_ job: CleanerJob) -> Bool {
        guard job.status.canClean, job.kind != .unknown, job.plan.propertyEditsAreValid,
              !buildSteps(for: job).isEmpty else { return false }
        if job.plan.changeWordTraces, job.isWordDocument, !preferences.wordDateRangeValid { return false }
        return true
    }

    /// Builds a new copy from the original: provenance cleaning, then Word
    /// editing traces, then property edits, each step reading the previous
    /// step's output. A failed or cancelled build keeps the previous copy.
    func createCopy(jobID: CleanerJob.ID) async {
        guard let job = job(withID: jobID), canCreateCopy(job) else { return }
        let plan = job.plan
        let steps = buildSteps(for: job)
        let previousOutputURL = job.stagedOutputURL
        update(jobID) {
            $0.status = .cleaning
            $0.activeStep = steps.first?.kind
        }

        var stagingDirectories: [URL] = []
        var results: [BuildStepResult] = []
        var currentStep = steps[0].kind
        do {
            var inputURL = job.sourceURL
            var outputKind = job.kind
            for step in steps {
                currentStep = step.kind
                update(jobID) { $0.activeStep = step.kind }
                let outputURL = try makeStagingURL(for: job)
                stagingDirectories.append(outputURL.deletingLastPathComponent())
                let stepInputURL = inputURL
                let result = try await withTrackedRequest(for: jobID) { requestID in
                    try await engine.clean(
                        fileAt: stepInputURL,
                        outputURL: outputURL,
                        options: step.options,
                        requestID: requestID
                    )
                }
                results.append(BuildStepResult(kind: step.kind, options: step.options, report: result.report))
                inputURL = result.outputURL
                outputKind = result.kind
            }

            currentStep = .checking
            update(jobID) { $0.activeStep = .checking }
            let finalURL = inputURL
            var postInspection: WatermarkReport?
            var postInspectionCompleted = true
            do {
                postInspection = try await withTrackedRequest(for: jobID) { requestID in
                    try await engine.inspect(fileAt: finalURL, requestID: requestID).report
                }
            } catch where isCancellation(error) {
                throw error
            } catch {
                postInspectionCompleted = false
                engineAvailabilityMessage = "The copy was created, but checking it failed: \(error.localizedDescription)"
            }

            let cleanStep = results.first { $0.kind == .provenance }
            update(jobID) { current in
                current.kind = outputKind
                current.cleanReport = cleanStep?.report
                current.cleaningOptions = cleanStep?.options
                current.buildSteps = results
                current.appliedPlan = plan
                current.postCleanInspection = postInspection
                current.stagedOutputURL = finalURL
                current.activeStep = nil
                current.resultRevision += 1
                current.status = Self.resultStatus(
                    postInspection: postInspection,
                    postInspectionCompleted: postInspectionCompleted,
                    cleanReport: cleanStep?.report
                )
            }
            // Keep only the final step's directory; earlier steps were inputs.
            for directory in stagingDirectories.dropLast() {
                try? fileManager.removeItem(at: directory)
            }
            if let previousOutputURL, previousOutputURL != finalURL {
                try? fileManager.removeItem(at: previousOutputURL.deletingLastPathComponent())
            }
        } catch where isCancellation(error) {
            stagingDirectories.forEach { try? fileManager.removeItem(at: $0) }
            update(jobID) { current in
                current.status = .cancelled
                current.activeStep = nil
                current.stagedOutputURL = previousOutputURL
            }
        } catch {
            stagingDirectories.forEach { try? fileManager.removeItem(at: $0) }
            let message = steps.count > 1
                ? "\(currentStep.title) failed: \(error.localizedDescription)"
                : error.localizedDescription
            update(jobID) { current in
                current.status = .failed(message)
                current.activeStep = nil
                current.stagedOutputURL = previousOutputURL
            }
        }
    }

    func exportSelectedCopy(to destinationURL: URL) async {
        guard let selectedJobID else {
            present(FileExportError.noStagedOutput, title: "Nothing to save")
            return
        }

        await exportCopy(jobID: selectedJobID, to: destinationURL)
    }

    func exportCopy(jobID: CleanerJob.ID, to destinationURL: URL) async {
        guard let job = job(withID: jobID), let stagedURL = job.stagedOutputURL else {
            present(FileExportError.noStagedOutput, title: "Nothing to save")
            return
        }

        do {
            let exportedURL = try await exporter.exportCopy(from: stagedURL, to: destinationURL)
            update(jobID) { $0.status = .exported(exportedURL) }
        } catch {
            present(error, title: "Couldn't save the copy")
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
        } catch {
            present(error, title: "Couldn't replace the original")
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

    nonisolated static func inspectionStatus(kind: WatermarkKind, report: WatermarkReport) -> CleanerJobStatus {
        if kind == .unknown {
            return .unsupported("The engine couldn't classify this file.")
        }
        if report.inspectionIncomplete {
            return .inspectionIncomplete(report.actionableFindings.count)
        }
        if report.hasActionableFindings {
            return .findings(max(1, report.actionableFindings.count))
        }
        return .inspectedClean
    }

    nonisolated static func resultStatus(
        postInspection: WatermarkReport?,
        postInspectionCompleted: Bool,
        cleanReport: WatermarkReport?
    ) -> CleanerJobStatus {
        if !postInspectionCompleted || postInspection?.inspectionIncomplete == true
            || cleanReport?.pdfDeepCleaningIncomplete == true {
            return .cleanedInspectionIncomplete
        }
        if let postInspection, postInspection.hasActionableFindings {
            return .readyToExport(residualCount: max(1, postInspection.actionableFindings.count))
        }
        return .readyToExport(residualCount: cleanReport?.postFindings.count ?? 0)
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
