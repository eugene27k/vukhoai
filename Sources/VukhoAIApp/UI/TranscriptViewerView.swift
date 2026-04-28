import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptViewerView: View {
    let job: ImportJob

    @Environment(\.dismiss) private var dismiss

    @State private var showSpeakers = true
    @State private var showTimestamps = true
    @State private var parsedLines: [TranscriptLine] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Toggle("Show speakers", isOn: $showSpeakers)
                Toggle("Show timestamps", isOn: $showTimestamps)

                Spacer()

                Button("Copy") {
                    copyCurrentText()
                }

                Button("Export TXT") {
                    exportCurrentText()
                }

                Button("Close", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(renderedText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 600)
        .task {
            loadTranscript()
        }
        .alert("Transcript Error", isPresented: isShowingError) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var renderedText: String {
        parsedLines
            .map { $0.render(showSpeakers: showSpeakers, showTimestamps: showTimestamps) }
            .joined(separator: "\n")
    }

    private func loadTranscript() {
        guard let outputPath = job.outputTXTPath else {
            errorMessage = "Output path is missing for selected job."
            parsedLines = []
            return
        }

        do {
            let content = try String(contentsOfFile: outputPath, encoding: .utf8)
            parsedLines = content
                .components(separatedBy: .newlines)
                .map { TranscriptLine.parse($0) }
        } catch {
            errorMessage = "Unable to read transcript file: \(error.localizedDescription)"
            parsedLines = []
        }
    }

    private func copyCurrentText() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(renderedText, forType: .string)
    }

    private func exportCurrentText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]

        let defaultName = URL(fileURLWithPath: job.inputFilename)
            .deletingPathExtension()
            .lastPathComponent + "-custom.txt"
        panel.nameFieldStringValue = defaultName

        guard panel.runModal() == .OK, let targetURL = panel.url else {
            return
        }

        do {
            try renderedText.write(to: targetURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to export TXT: \(error.localizedDescription)"
        }
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
}

private struct TranscriptLine {
    let start: String?
    let end: String?
    let speaker: String?
    let text: String
    let raw: String

    static func parse(_ line: String) -> TranscriptLine {
        let pattern = #"^\[([0-9:.]+)\s-\s([0-9:.]+)\]\s+(SPEAKER_[0-9]+):\s*(.*)$"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return TranscriptLine(start: nil, end: nil, speaker: nil, text: line, raw: line)
        }

        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges == 5 else {
            return TranscriptLine(start: nil, end: nil, speaker: nil, text: line, raw: line)
        }

        func extract(_ idx: Int) -> String {
            let nsRange = match.range(at: idx)
            guard let swiftRange = Range(nsRange, in: line) else { return "" }
            return String(line[swiftRange])
        }

        return TranscriptLine(
            start: extract(1),
            end: extract(2),
            speaker: extract(3),
            text: extract(4),
            raw: line
        )
    }

    func render(showSpeakers: Bool, showTimestamps: Bool) -> String {
        guard let start, let end, let speaker else {
            return raw
        }

        var prefixParts: [String] = []
        if showTimestamps {
            prefixParts.append("[\(start) - \(end)]")
        }
        if showSpeakers {
            prefixParts.append("\(speaker):")
        }

        if prefixParts.isEmpty {
            return text
        }

        return "\(prefixParts.joined(separator: " ")) \(text)"
    }
}
