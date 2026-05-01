import Foundation

@MainActor
final class QueueProcessor: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var activeJobID: String?
    @Published private(set) var progressByJobID: [String: JobProgressSnapshot] = [:]
    @Published private(set) var pausedJobIDs: Set<String> = []
    @Published private(set) var processingStartedAtByJobID: [String: Date] = [:]

    private var loopTask: Task<Void, Never>?
    private unowned let jobStore: JobStore
    private unowned let settings: AppSettings

    private var activeExecution: TranscriptionExecution?
    private var cancellationRequests: Set<String> = []
    private var pendingDeletionRequests: Set<String> = []

    init(jobStore: JobStore, settings: AppSettings) {
        self.jobStore = jobStore
        self.settings = settings
    }

    func start() {
        guard loopTask == nil else { return }

        isRunning = true
        loopTask = Task(priority: .utility) { [weak self] in
            await self?.processingLoop()
        }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        if let activeJobID {
            cancellationRequests.insert(activeJobID)
            activeExecution?.cancel()
        }
    }

    func nudge() {
        if loopTask == nil {
            start()
        }
    }

    func pause(jobID: String) {
        guard activeJobID == jobID else { return }
        pausedJobIDs.insert(jobID)
        activeExecution?.pause()
    }

    func resume(jobID: String) {
        guard activeJobID == jobID else { return }
        pausedJobIDs.remove(jobID)
        activeExecution?.resume()
    }

    func cancel(jobID: String) {
        if activeJobID == jobID {
            cancellationRequests.insert(jobID)
            pausedJobIDs.remove(jobID)
            activeExecution?.cancel()
            return
        }

        jobStore.cancel(jobID: jobID)
        progressByJobID.removeValue(forKey: jobID)
        pausedJobIDs.remove(jobID)
    }

    func delete(jobID: String) {
        if activeJobID == jobID {
            pendingDeletionRequests.insert(jobID)
            cancellationRequests.insert(jobID)
            pausedJobIDs.remove(jobID)
            activeExecution?.cancel()
            return
        }

        jobStore.remove(jobID: jobID)
        progressByJobID.removeValue(forKey: jobID)
        pausedJobIDs.remove(jobID)
        cancellationRequests.remove(jobID)
        pendingDeletionRequests.remove(jobID)
        processingStartedAtByJobID.removeValue(forKey: jobID)
    }

    private func processingLoop() async {
        while !Task.isCancelled {
            do {
                if let job = try jobStore.claimNextQueuedJob() {
                    try await process(job: job)
                    continue
                }
            } catch {
                print("Queue polling error: \(error.localizedDescription)")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func process(job: ImportJob) async throws {
        activeJobID = job.id
        processingStartedAtByJobID[job.id] = Date()
        progressByJobID[job.id] = .preparing()

        do {
            settings.ensureOutputFolderExists()

            let prepared = try await AudioPreprocessor.prepare(
                inputURL: URL(fileURLWithPath: job.inputPath),
                jobID: job.id,
                normalizedDirectory: jobStore.paths.normalizedAudioDirectory
            )

            if pendingDeletionRequests.contains(job.id) {
                jobStore.remove(jobID: job.id)
                clearRuntimeState(for: job.id)
                return
            }

            if cancellationRequests.contains(job.id) {
                jobStore.cancel(jobID: job.id)
                clearRuntimeState(for: job.id)
                return
            }

            jobStore.updatePreparedAudio(
                jobID: job.id,
                normalizedPath: prepared.url.path,
                durationSeconds: prepared.durationSeconds
            )

            let outputURL = jobStore.outputURL(for: job)
            let metaURL = jobStore.metaURL(for: job)

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            progressByJobID[job.id] = JobProgressSnapshot(
                percent: 4,
                etaSeconds: nil,
                stage: "Starting transcription",
                updatedAt: Date()
            )

            let execution = try TranscriptionRunner.prepareExecution(
                inputAudioPath: prepared.url.path,
                outputTXTPath: outputURL.path,
                metaJSONPath: metaURL.path,
                profile: job.profile,
                language: job.languageMode,
                diarizationEnabled: job.diarizationEnabled,
                durationSeconds: prepared.durationSeconds,
                onProgress: { [weak self] event in
                    Task { @MainActor in
                        guard let self else { return }
                        self.progressByJobID[job.id] = JobProgressSnapshot(
                            percent: event.percent,
                            etaSeconds: event.etaSeconds,
                            stage: event.stage,
                            updatedAt: Date()
                        )
                    }
                }
            )

            activeExecution = execution

            if pausedJobIDs.contains(job.id) {
                execution.pause()
            }

            let result = try await runExecutionInBackground(execution)

            if pendingDeletionRequests.contains(job.id) {
                jobStore.remove(jobID: job.id)
            } else if cancellationRequests.contains(job.id) {
                jobStore.cancel(jobID: job.id)
            } else if result.exitCode == 0 {
                jobStore.markDone(jobID: job.id, outputTXTPath: outputURL.path, metaJSONPath: metaURL.path)
            } else {
                let combinedError = [result.errorOutput, result.output]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = combinedError.isEmpty ? "Transcription failed with exit code \(result.exitCode)." : combinedError
                jobStore.markFailed(jobID: job.id, errorMessage: message)
            }
        } catch is CancellationError {
            if pendingDeletionRequests.contains(job.id) {
                jobStore.remove(jobID: job.id)
            } else {
                jobStore.cancel(jobID: job.id)
            }
        } catch {
            if pendingDeletionRequests.contains(job.id) {
                jobStore.remove(jobID: job.id)
            } else {
                jobStore.markFailed(jobID: job.id, errorMessage: error.localizedDescription)
            }
        }

        clearRuntimeState(for: job.id)
    }

    private func clearRuntimeState(for jobID: String) {
        activeExecution = nil
        activeJobID = nil
        progressByJobID.removeValue(forKey: jobID)
        pausedJobIDs.remove(jobID)
        cancellationRequests.remove(jobID)
        pendingDeletionRequests.remove(jobID)
        processingStartedAtByJobID.removeValue(forKey: jobID)
    }

    private func runExecutionInBackground(_ execution: TranscriptionExecution) async throws -> TranscriptionRunResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try execution.run())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
