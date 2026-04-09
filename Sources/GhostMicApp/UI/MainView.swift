import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var jobStore: JobStore
    @EnvironmentObject private var queueProcessor: QueueProcessor

    @State private var selectedImportURL: URL?
    @State private var transcriptToOpen: ImportJob?
    @State private var protocolToOpen: ProtocolSheetItem?
    @State private var errorMessage: String?
    @State private var duplicatePrompt: DuplicateImportPrompt?
    @State private var deletePrompt: DeleteJobPrompt?
    @State private var isShowingSettingsSheet = false
    @State private var generatingProtocolJobIDs: Set<String> = []
    @State private var listFilter: JobListFilter = .all
    @State private var liveDurationTick = Date()
    private let liveDurationTicker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 16) {
            importPanel
            queuePanel
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 660)
        .sheet(item: $transcriptToOpen) { job in
            TranscriptViewerView(job: job)
        }
        .sheet(item: $protocolToOpen) { sheetItem in
            ProtocolViewerView(title: sheetItem.title, protocolPath: sheetItem.path)
        }
        .sheet(isPresented: $isShowingSettingsSheet) {
            SettingsView(showsCloseButton: true)
                .environmentObject(settings)
                .frame(minWidth: 680, minHeight: 520)
        }
        .alert("Error", isPresented: isShowingError) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(item: $duplicatePrompt) { prompt in
            Alert(
                title: Text("File Already In List"),
                message: Text(prompt.message),
                primaryButton: .default(Text("Transcribe Anyway")) {
                    enqueueFile(prompt.url)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $deletePrompt) { prompt in
            Alert(
                title: Text("Delete Record"),
                message: Text(prompt.message),
                primaryButton: .destructive(Text("Delete")) {
                    queueProcessor.delete(jobID: prompt.jobID)
                },
                secondaryButton: .cancel()
            )
        }
        .onReceive(liveDurationTicker) { value in
            liveDurationTick = value
        }
    }

    private var importPanel: some View {
        GroupBox("Import") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drop .m4a/.mp4 file here or choose one from disk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [8]))
                    .foregroundStyle(.tertiary)
                    .frame(height: 120)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.title2)
                            Text(selectedImportURL?.lastPathComponent ?? "No file selected")
                                .font(.callout)
                                .lineLimit(1)
                        }
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let first = urls.first else { return false }
                        return handlePickedFile(first)
                    }

                HStack(spacing: 12) {
                    Button("Import File...") {
                        openFilePicker()
                    }

                    Button("Transcribe") {
                        transcribeSelected()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedImportURL == nil && !jobStore.jobs.contains { $0.status == .queued })

                    Button("Settings") {
                        isShowingSettingsSheet = true
                    }

                    if queueProcessor.isRunning {
                        Label("Worker active", systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(12)
        }
    }

    private var queuePanel: some View {
        GroupBox("Queue and Transcriptions") {
            VStack(spacing: 10) {
                HStack {
                    Picker("View", selection: $listFilter) {
                        ForEach(JobListFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)

                    Spacer()

                    Text("\(filteredJobs.count) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                List(filteredJobs) { job in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.inputFilename)
                                .font(.headline)

                            HStack(spacing: 10) {
                                Text(Self.dateFormatter.string(from: job.createdAt))
                                Text(durationText(for: job, now: liveDurationTick))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            if job.status == .processing {
                                processingStatus(for: job)
                            }

                            if let protocolError = job.protocolErrorMessage, !protocolError.isEmpty {
                                Text("Protocol error: \(protocolError)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(3)
                            }

                            if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }

                        Spacer()

                        Text(job.status.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusColor(job.status).opacity(0.15), in: Capsule())
                            .foregroundStyle(statusColor(job.status))

                        rowActions(for: job)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    private var filteredJobs: [ImportJob] {
        switch listFilter {
        case .all:
            return jobStore.jobs
        case .completedOnly:
            return jobStore.jobs.filter { $0.status == .done }
        }
    }

    @ViewBuilder
    private func processingStatus(for job: ImportJob) -> some View {
        if let snapshot = queueProcessor.progressByJobID[job.id] {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: snapshot.percent, total: 100)
                    .frame(maxWidth: 280)
                HStack(spacing: 8) {
                    Text("\(Int(snapshot.percent.rounded()))%")
                    if let etaSeconds = snapshot.etaSeconds, etaSeconds.isFinite, etaSeconds >= 0 {
                        Text("ETA ~\(etaText(etaSeconds))")
                    }
                    Text(snapshot.stage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func rowActions(for job: ImportJob) -> some View {
        HStack(spacing: 8) {
            if job.status == .done {
                Button("Open") {
                    guard let outputPath = job.outputTXTPath,
                          FileManager.default.fileExists(atPath: outputPath) else {
                        errorMessage = "Transcription file was not found on disk."
                        return
                    }
                    transcriptToOpen = job
                }

                Button("Re-transcribe") {
                    reTranscribe(job)
                }

                protocolAction(for: job)
            }

            if job.status == .queued {
                Button("Cancel") {
                    queueProcessor.cancel(jobID: job.id)
                }
            }

            if job.status == .processing {
                if queueProcessor.pausedJobIDs.contains(job.id) {
                    Button("Resume") {
                        queueProcessor.resume(jobID: job.id)
                    }
                } else {
                    Button("Pause") {
                        queueProcessor.pause(jobID: job.id)
                    }
                }

                Button("Cancel", role: .destructive) {
                    queueProcessor.cancel(jobID: job.id)
                }
            }

            if job.status == .failed {
                Button("Retry") {
                    jobStore.retry(jobID: job.id)
                    queueProcessor.nudge()
                }
            }

            Button("Delete", role: .destructive) {
                requestDelete(job)
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func protocolAction(for job: ImportJob) -> some View {
        if generatingProtocolJobIDs.contains(job.id) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating Protocol")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        } else if let protocolPath = job.protocolPath,
                  FileManager.default.fileExists(atPath: protocolPath) {
            Button("View Protocol") {
                protocolToOpen = ProtocolSheetItem(
                    id: job.id,
                    title: "Protocol - \(job.inputFilename)",
                    path: protocolPath
                )
            }
        } else {
            Button(job.protocolErrorMessage == nil ? "Generate Protocol" : "Retry Protocol") {
                generateProtocol(for: job)
            }
        }
    }

    private func requestDelete(_ job: ImportJob) {
        let message: String
        if job.status == .processing {
            message = "This record is currently processing. It will be cancelled and fully removed from the list."
        } else {
            message = "Record \"\(job.inputFilename)\" will be fully removed from the list."
        }

        deletePrompt = DeleteJobPrompt(jobID: job.id, message: message)
    }

    private func generateProtocol(for job: ImportJob) {
        guard let transcriptPath = job.outputTXTPath,
              FileManager.default.fileExists(atPath: transcriptPath) else {
            errorMessage = "Transcript file is missing. Re-transcribe first."
            return
        }

        guard let apiKey = settings.openAIAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "OpenAI API key is not configured. Set it in Settings > AI Protocols."
            return
        }

        generatingProtocolJobIDs.insert(job.id)
        jobStore.markProtocolFailed(jobID: job.id, errorMessage: nil)

        Task {
            defer {
                Task { @MainActor in
                    generatingProtocolJobIDs.remove(job.id)
                }
            }

            do {
                let rawTranscript = try String(contentsOfFile: transcriptPath, encoding: .utf8)
                let cleanedTranscript = cleanedTranscriptForProtocol(rawTranscript)
                guard !cleanedTranscript.isEmpty else {
                    throw NSError(domain: "VukhoAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transcript is empty."])
                }

                let protocolMarkdown = try await OpenAIProtocolService.shared.generateMeetingProtocol(
                    apiKey: apiKey,
                    model: settings.openAIModel,
                    transcript: cleanedTranscript
                )

                let protocolURL = jobStore.protocolURL(for: job)
                try FileManager.default.createDirectory(
                    at: protocolURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try protocolMarkdown.write(to: protocolURL, atomically: true, encoding: .utf8)

                await MainActor.run {
                    jobStore.markProtocolReady(jobID: job.id, protocolPath: protocolURL.path)
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    jobStore.markProtocolFailed(jobID: job.id, errorMessage: message)
                    errorMessage = "Protocol generation failed: \(message)"
                }
            }
        }
    }

    private func cleanedTranscriptForProtocol(_ raw: String) -> String {
        let pattern = #"^\[[0-9:.]+\s-\s[0-9:.]+\]\s*(SPEAKER_[0-9]+):\s*(.*)$"#
        let regex = try? NSRegularExpression(pattern: pattern)

        return raw
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                guard let regex else { return trimmed }
                let range = NSRange(location: 0, length: trimmed.utf16.count)
                guard let match = regex.firstMatch(in: trimmed, options: [], range: range), match.numberOfRanges == 3 else {
                    return trimmed
                }

                let speakerRange = Range(match.range(at: 1), in: trimmed)
                let textRange = Range(match.range(at: 2), in: trimmed)
                guard let speakerRange, let textRange else {
                    return trimmed
                }

                let speaker = String(trimmed[speakerRange])
                let text = String(trimmed[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : "\(speaker): \(text)"
            }
            .joined(separator: "\n")
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .audio]

        guard panel.runModal() == .OK, let picked = panel.url else {
            return
        }

        _ = handlePickedFile(picked)
    }

    private func handlePickedFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "mp4"].contains(ext) else {
            errorMessage = "Unsupported format. Use .m4a or .mp4."
            return false
        }

        selectedImportURL = url
        return true
    }

    private func transcribeSelected() {
        if let selectedImportURL {
            let duplicates = duplicateJobs(for: selectedImportURL)
            if !duplicates.isEmpty {
                duplicatePrompt = DuplicateImportPrompt(
                    url: selectedImportURL,
                    message: duplicateMessage(for: selectedImportURL, duplicates: duplicates)
                )
                return
            }

            enqueueFile(selectedImportURL)
        } else {
            queueProcessor.nudge()
        }
    }

    private func enqueueFile(_ url: URL) {
        do {
            try jobStore.enqueue(fileURL: url)
            if selectedImportURL == url {
                selectedImportURL = nil
            }
            queueProcessor.nudge()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reTranscribe(_ job: ImportJob) {
        let fileURL = URL(fileURLWithPath: job.inputPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            errorMessage = "Original input file is not available anymore: \(job.inputFilename)"
            return
        }

        enqueueFile(fileURL)
    }

    private func duplicateJobs(for url: URL) -> [ImportJob] {
        let canonicalTargetPath = canonicalPath(url)
        let targetFilename = url.lastPathComponent.lowercased()

        return jobStore.jobs.filter { job in
            let jobURL = URL(fileURLWithPath: job.inputPath)
            let samePath = canonicalPath(jobURL) == canonicalTargetPath
            let sameFilename = job.inputFilename.lowercased() == targetFilename
            return samePath || sameFilename
        }
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func duplicateMessage(for url: URL, duplicates: [ImportJob]) -> String {
        let canonicalTargetPath = canonicalPath(url)
        let hasExactMatch = duplicates.contains {
            canonicalPath(URL(fileURLWithPath: $0.inputPath)) == canonicalTargetPath
        }

        if hasExactMatch {
            return "This exact file is already in the transcription list. You can still create another transcription job for it."
        }

        return "A file with the same name is already in the list. You can still transcribe this file anyway."
    }

    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .queued:
            return .orange
        case .processing:
            return .blue
        case .done:
            return .green
        case .failed:
            return .red
        }
    }

    private func durationText(for job: ImportJob, now: Date) -> String {
        if job.status == .processing,
           let startedAt = queueProcessor.processingStartedAtByJobID[job.id] {
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            return "Elapsed: \(formattedClock(elapsed))"
        }

        guard let duration = job.durationSeconds, duration.isFinite, duration > 0 else {
            return "Duration: --"
        }

        return "Duration: \(formattedClock(duration))"
    }

    private func formattedClock(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: seconds) ?? "--"
    }

    private func etaText(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "--"
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { newValue in
                if !newValue {
                    errorMessage = nil
                }
            }
        )
    }


    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct DuplicateImportPrompt: Identifiable {
    let id = UUID()
    let url: URL
    let message: String
}

private struct DeleteJobPrompt: Identifiable {
    let id = UUID()
    let jobID: String
    let message: String
}

private struct ProtocolSheetItem: Identifiable {
    let id: String
    let title: String
    let path: String
}

private enum JobListFilter: String, CaseIterable, Identifiable {
    case all
    case completedOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "All"
        case .completedOnly:
            return "Completed only"
        }
    }
}
