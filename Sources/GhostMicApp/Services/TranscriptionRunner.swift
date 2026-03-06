import Darwin
import Foundation

struct TranscriptionRunResult {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

struct TranscriptionProgressEvent {
    let percent: Double
    let etaSeconds: Double?
    let stage: String
}

enum TranscriptionRunner {
    static func prepareExecution(
        inputAudioPath: String,
        outputTXTPath: String,
        metaJSONPath: String,
        profile: TranscriptionProfile,
        language: LanguageMode,
        diarizationEnabled: Bool,
        durationSeconds: Double,
        onProgress: @escaping (TranscriptionProgressEvent) -> Void
    ) throws -> TranscriptionExecution {
        guard let scriptURL = Bundle.module.url(forResource: "transcribe", withExtension: "py") else {
            throw RunnerError.scriptMissing
        }

        let pythonURL = try resolvePythonExecutable()
        try ensureRequiredModules(pythonURL: pythonURL)

        let args = [
            scriptURL.path,
            "--input", inputAudioPath,
            "--output", outputTXTPath,
            "--meta", metaJSONPath,
            "--profile", profile.pythonFlag,
            "--language", language.pythonFlag,
            "--diarization", diarizationEnabled ? "on" : "off",
            "--duration-seconds", String(format: "%.3f", durationSeconds)
        ]

        return TranscriptionExecution(
            pythonURL: pythonURL,
            arguments: args,
            onProgress: onProgress
        )
    }

    private static func resolvePythonExecutable() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["GHOSTMIC_PYTHON"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let cwdVenv = cwd.appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: cwdVenv.path) {
            return cwdVenv
        }

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let homeVenv = home.appendingPathComponent(".venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: homeVenv.path) {
            return homeVenv
        }

        let fallbacks = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]

        for path in fallbacks where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        throw RunnerError.pythonNotFound
    }

    private static func ensureRequiredModules(pythonURL: URL) throws {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('faster_whisper') else 1)"]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RunnerError.missingPythonDependencies(detail: detail)
        }
    }

    enum RunnerError: LocalizedError {
        case scriptMissing
        case pythonNotFound
        case missingPythonDependencies(detail: String?)

        var errorDescription: String? {
            switch self {
            case .scriptMissing:
                return "Bundled transcription script is missing."
            case .pythonNotFound:
                return "Python 3 was not found. Install Python 3 and run setup from README."
            case let .missingPythonDependencies(detail):
                let suffix = detail.map { " Details: \($0)" } ?? ""
                return "Missing Python dependencies for transcription. Activate .venv and run: pip install -r Scripts/requirements.txt.\(suffix)"
            }
        }
    }
}

final class TranscriptionExecution {
    private struct ProgressPayload: Decodable {
        let percent: Double
        let eta_seconds: Double?
        let stage: String?
    }

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let controlQueue = DispatchQueue(label: "GhostMic.TranscriptionExecution.Control")
    private let ioQueue = DispatchQueue(label: "GhostMic.TranscriptionExecution.IO")
    private let onProgress: (TranscriptionProgressEvent) -> Void

    private var started = false
    private var paused = false
    private var pendingPause = false
    private var cancellationRequested = false

    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var pendingStdoutLine = ""
    private var pendingStderrLine = ""

    init(pythonURL: URL, arguments: [String], onProgress: @escaping (TranscriptionProgressEvent) -> Void) {
        self.onProgress = onProgress

        process.executableURL = pythonURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
    }

    func run() throws -> TranscriptionRunResult {
        try setupReadHandlers()

        let shouldCancelBeforeStart = controlQueue.sync { cancellationRequested }
        if shouldCancelBeforeStart {
            throw CancellationError()
        }

        try process.run()

        controlQueue.sync {
            started = true
        }

        applyPendingPauseIfNeeded()

        if controlQueue.sync(execute: { cancellationRequested }) {
            _ = terminateProcess()
        }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingOut.isEmpty {
            ioQueue.sync {
                self.consumeStdout(data: remainingOut)
            }
        }

        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingErr.isEmpty {
            ioQueue.sync {
                self.consumeStderr(data: remainingErr)
            }
        }

        ioQueue.sync {
            flushPendingLines()
        }

        return ioQueue.sync {
            TranscriptionRunResult(
                output: stdoutBuffer,
                errorOutput: stderrBuffer,
                exitCode: process.terminationStatus
            )
        }
    }

    func pause() {
        let pid = controlQueue.sync { () -> pid_t? in
            if started, process.isRunning {
                paused = true
                return pid_t(process.processIdentifier)
            }

            pendingPause = true
            paused = true
            return nil
        }

        if let pid {
            _ = kill(pid, SIGSTOP)
        }
    }

    func resume() {
        let pid = controlQueue.sync { () -> pid_t? in
            pendingPause = false
            guard started, process.isRunning else {
                paused = false
                return nil
            }

            paused = false
            return pid_t(process.processIdentifier)
        }

        if let pid {
            _ = kill(pid, SIGCONT)
        }
    }

    func cancel() {
        let shouldTerminate = controlQueue.sync { () -> Bool in
            cancellationRequested = true
            return started && process.isRunning
        }

        if shouldTerminate {
            _ = terminateProcess()
        }
    }

    func isPaused() -> Bool {
        controlQueue.sync { paused }
    }

    private func setupReadHandlers() throws {
        let outHandle = stdoutPipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.ioQueue.async {
                self.consumeStdout(data: data)
            }
        }

        let errHandle = stderrPipe.fileHandleForReading
        errHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.ioQueue.async {
                self.consumeStderr(data: data)
            }
        }
    }

    private func applyPendingPauseIfNeeded() {
        let shouldPause = controlQueue.sync { pendingPause && process.isRunning }
        if shouldPause {
            _ = kill(pid_t(process.processIdentifier), SIGSTOP)
        }
    }

    private func terminateProcess() -> Bool {
        if process.isRunning {
            process.terminate()
            return true
        }
        return false
    }

    private func consumeStdout(data: Data) {
        let chunk = String(data: data, encoding: .utf8) ?? ""
        processLines(
            chunk: chunk,
            pending: &pendingStdoutLine,
            onLine: { line in
                if let event = parseProgress(from: line) {
                    onProgress(event)
                    return
                }
                stdoutBuffer.append(line)
                stdoutBuffer.append("\n")
            }
        )
    }

    private func consumeStderr(data: Data) {
        let chunk = String(data: data, encoding: .utf8) ?? ""
        processLines(
            chunk: chunk,
            pending: &pendingStderrLine,
            onLine: { line in
                stderrBuffer.append(line)
                stderrBuffer.append("\n")
            }
        )
    }

    private func flushPendingLines() {
        if !pendingStdoutLine.isEmpty {
            if let event = parseProgress(from: pendingStdoutLine) {
                onProgress(event)
            } else {
                stdoutBuffer.append(pendingStdoutLine)
                stdoutBuffer.append("\n")
            }
            pendingStdoutLine = ""
        }

        if !pendingStderrLine.isEmpty {
            stderrBuffer.append(pendingStderrLine)
            stderrBuffer.append("\n")
            pendingStderrLine = ""
        }
    }

    private func processLines(chunk: String, pending: inout String, onLine: (String) -> Void) {
        pending.append(chunk)

        while let range = pending.range(of: "\n") {
            var line = String(pending[..<range.lowerBound])
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            onLine(line)
            pending.removeSubrange(pending.startIndex...range.lowerBound)
        }
    }

    private func parseProgress(from line: String) -> TranscriptionProgressEvent? {
        let prefix = "GHOSTMIC_PROGRESS "
        guard line.hasPrefix(prefix) else { return nil }

        let jsonString = String(line.dropFirst(prefix.count))
        guard let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ProgressPayload.self, from: data) else {
            return nil
        }

        let boundedPercent = max(0, min(payload.percent, 100))
        let stage = payload.stage?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionProgressEvent(
            percent: boundedPercent,
            etaSeconds: payload.eta_seconds,
            stage: (stage?.isEmpty == false ? stage! : "Transcribing")
        )
    }
}

extension TranscriptionExecution: @unchecked Sendable {}
