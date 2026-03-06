import SwiftUI

struct SettingsView: View {
    let showsCloseButton: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State private var errorMessage: String?
    @State private var openAIAPIKeyDraft = ""
    @State private var connectionStatusMessage: String?
    @State private var connectionStatusIsError = false
    @State private var isTestingConnection = false

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Transcription") {
                    Picker("Quality profile", selection: $settings.defaultProfile) {
                        ForEach(TranscriptionProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }

                    Picker("Language", selection: $settings.languageMode) {
                        ForEach(LanguageMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    Toggle("Enable diarization", isOn: $settings.diarizationEnabled)
                }

                Section("AI Protocols") {
                    TextField("OpenAI model", text: $settings.openAIModel)
                        .textFieldStyle(.roundedBorder)

                    SecureField("OpenAI API key", text: $openAIAPIKeyDraft)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button("Save API Key") {
                            saveAPIKey()
                        }

                        Button("Clear Key", role: .destructive) {
                            clearAPIKey()
                        }

                        Spacer()

                        if settings.hasOpenAIAPIKey {
                            Label("Key saved", systemImage: "checkmark.seal")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("No key", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(isTestingConnection)

                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let status = connectionStatusMessage, !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(connectionStatusIsError ? .red : .green)
                    }
                }

                Section("Output") {
                    HStack {
                        Text(settings.outputFolderPath)
                            .font(.footnote.monospaced())
                            .lineLimit(2)

                        Spacer()

                        Button("Choose Folder...") {
                            chooseOutputFolder()
                        }
                    }
                }
            }
            .padding(16)

            if showsCloseButton {
                Divider()
                HStack {
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 680)
        .onAppear {
            openAIAPIKeyDraft = settings.openAIAPIKey() ?? ""
        }
        .alert("Settings Error", isPresented: isShowingError) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveAPIKey() {
        do {
            try settings.saveOpenAIAPIKey(openAIAPIKeyDraft)
            connectionStatusMessage = "API key saved."
            connectionStatusIsError = false
        } catch {
            connectionStatusMessage = nil
            errorMessage = "Unable to save API key: \(error.localizedDescription)"
        }
    }

    private func clearAPIKey() {
        do {
            try settings.clearOpenAIAPIKey()
            openAIAPIKeyDraft = ""
            connectionStatusMessage = "API key removed."
            connectionStatusIsError = false
        } catch {
            connectionStatusMessage = nil
            errorMessage = "Unable to clear API key: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        connectionStatusMessage = nil
        connectionStatusIsError = false

        guard let apiKey = settings.openAIAPIKey(), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionStatusMessage = "Set API key first."
            connectionStatusIsError = true
            return
        }

        isTestingConnection = true
        defer { isTestingConnection = false }

        do {
            try await OpenAIProtocolService.shared.testConnection(apiKey: apiKey, model: settings.openAIModel)
            connectionStatusMessage = "Connection successful."
            connectionStatusIsError = false
        } catch {
            connectionStatusMessage = error.localizedDescription
            connectionStatusIsError = true
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let picked = panel.url else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            settings.setOutputFolder(url: picked)
        } catch {
            errorMessage = "Unable to use selected output folder: \(error.localizedDescription)"
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
