import Foundation

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [ImportJob] = []

    let paths: GhostMicPaths

    private let repository: JobRepository
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        do {
            paths = try GhostMicPaths.build()
            repository = try JobRepository(databaseURL: paths.databaseURL)
            jobs = try repository.fetchAllJobs()
        } catch {
            fatalError("Unable to initialize storage: \(error)")
        }
    }

    func refresh() {
        do {
            jobs = try repository.fetchAllJobs()
        } catch {
            print("Failed to refresh jobs: \(error.localizedDescription)")
        }
    }

    func enqueue(fileURL: URL) throws {
        let ext = fileURL.pathExtension.lowercased()
        guard ["m4a", "mp4"].contains(ext) else {
            throw ImportError.unsupportedFormat
        }

        let job = ImportJob(
            id: UUID().uuidString,
            inputPath: fileURL.path,
            inputFilename: fileURL.lastPathComponent,
            normalizedAudioPath: nil,
            status: .queued,
            createdAt: Date(),
            durationSeconds: nil,
            profile: settings.defaultProfile,
            languageMode: settings.languageMode,
            diarizationEnabled: settings.diarizationEnabled,
            outputTXTPath: nil,
            metaJSONPath: nil,
            errorMessage: nil,
            protocolPath: nil,
            protocolErrorMessage: nil
        )

        try repository.insert(job: job)
        refresh()
    }

    func retry(jobID: String) {
        do {
            try repository.retry(jobID: jobID)
            refresh()
        } catch {
            print("Failed to retry job: \(error.localizedDescription)")
        }
    }

    func cancel(jobID: String, reason: String = "Cancelled by user.") {
        do {
            try repository.cancel(jobID: jobID, reason: reason)
            refresh()
        } catch {
            print("Failed to cancel job: \(error.localizedDescription)")
        }
    }

    func remove(jobID: String) {
        let target = job(id: jobID)

        do {
            try repository.delete(jobID: jobID)
            refresh()
        } catch {
            print("Failed to delete job: \(error.localizedDescription)")
            return
        }

        guard let target else { return }
        cleanupGeneratedFiles(for: target)
    }

    func claimNextQueuedJob() throws -> ImportJob? {
        let job = try repository.claimNextQueuedJob()
        refresh()
        return job
    }

    func updatePreparedAudio(jobID: String, normalizedPath: String, durationSeconds: Double) {
        do {
            try repository.updatePreparedAudio(jobID: jobID, normalizedPath: normalizedPath, durationSeconds: durationSeconds)
            refresh()
        } catch {
            print("Failed to update prepared audio: \(error.localizedDescription)")
        }
    }

    func markDone(jobID: String, outputTXTPath: String, metaJSONPath: String?) {
        do {
            try repository.markDone(jobID: jobID, outputTXTPath: outputTXTPath, metaJSONPath: metaJSONPath)
            refresh()
        } catch {
            print("Failed to mark done: \(error.localizedDescription)")
        }
    }

    func markFailed(jobID: String, errorMessage: String) {
        do {
            try repository.markFailed(jobID: jobID, errorMessage: errorMessage)
            refresh()
        } catch {
            print("Failed to mark failed: \(error.localizedDescription)")
        }
    }

    func markProtocolReady(jobID: String, protocolPath: String) {
        do {
            try repository.updateProtocolReady(jobID: jobID, protocolPath: protocolPath)
            refresh()
        } catch {
            print("Failed to mark protocol ready: \(error.localizedDescription)")
        }
    }

    func markProtocolFailed(jobID: String, errorMessage: String?) {
        do {
            try repository.updateProtocolFailed(jobID: jobID, errorMessage: errorMessage)
            refresh()
        } catch {
            print("Failed to mark protocol failed: \(error.localizedDescription)")
        }
    }

    func job(id: String) -> ImportJob? {
        jobs.first(where: { $0.id == id })
    }

    func outputURL(for job: ImportJob) -> URL {
        let outputDirectory = settings.outputFolderURL()
        let baseName = URL(fileURLWithPath: job.inputFilename).deletingPathExtension().lastPathComponent
        let shortID = String(job.id.prefix(8))
        let outputName = "\(baseName)-\(shortID).txt"
        return outputDirectory.appendingPathComponent(outputName, isDirectory: false)
    }

    func protocolURL(for job: ImportJob) -> URL {
        let outputDirectory = settings.outputFolderURL().appendingPathComponent("Protocols", isDirectory: true)
        let baseName = URL(fileURLWithPath: job.inputFilename).deletingPathExtension().lastPathComponent
        let shortID = String(job.id.prefix(8))
        let outputName = "\(baseName)-\(shortID)-protocol.md"
        return outputDirectory.appendingPathComponent(outputName, isDirectory: false)
    }

    func metaURL(for job: ImportJob) -> URL {
        paths.metadataDirectory.appendingPathComponent("\(job.id).json", isDirectory: false)
    }

    private func cleanupGeneratedFiles(for job: ImportJob) {
        deleteFileIfExists(path: job.outputTXTPath)
        deleteFileIfExists(path: job.metaJSONPath)
        deleteFileIfExists(path: job.protocolPath)

        if let normalizedPath = job.normalizedAudioPath,
           shouldDeleteNormalizedAudio(path: normalizedPath, inputPath: job.inputPath) {
            deleteFileIfExists(path: normalizedPath)
        }
    }

    private func shouldDeleteNormalizedAudio(path: String, inputPath: String) -> Bool {
        let normalized = canonicalPath(path)
        let input = canonicalPath(inputPath)
        if normalized == input {
            return false
        }

        let normalizedRoot = paths.normalizedAudioDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return normalized.hasPrefix(normalizedRoot + "/") || normalized == normalizedRoot
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func deleteFileIfExists(path: String?) {
        guard let path else { return }
        guard FileManager.default.fileExists(atPath: path) else { return }

        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            print("Failed to remove file at \(path): \(error.localizedDescription)")
        }
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Only .m4a and .mp4 are supported in MVP."
            }
        }
    }
}
