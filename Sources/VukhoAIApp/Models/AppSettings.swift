import Foundation

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let profile = "vukhoai.profile"
        static let languageMode = "vukhoai.language_mode"
        static let diarizationEnabled = "vukhoai.diarization_enabled"
        static let outputFolder = "vukhoai.output_folder"
        static let openAIModel = "vukhoai.openai_model"
    }

    private enum SecretKeys {
        static let service = "com.vukhoai.openai"
        static let account = "api_key"
    }

    @Published var defaultProfile: TranscriptionProfile {
        didSet { UserDefaults.standard.set(defaultProfile.rawValue, forKey: Keys.profile) }
    }

    @Published var languageMode: LanguageMode {
        didSet { UserDefaults.standard.set(languageMode.rawValue, forKey: Keys.languageMode) }
    }

    @Published var diarizationEnabled: Bool {
        didSet { UserDefaults.standard.set(diarizationEnabled, forKey: Keys.diarizationEnabled) }
    }

    @Published var outputFolderPath: String {
        didSet { UserDefaults.standard.set(outputFolderPath, forKey: Keys.outputFolder) }
    }

    @Published var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel) }
    }

    @Published private(set) var hasOpenAIAPIKey: Bool

    init() {
        let defaults = UserDefaults.standard
        defaultProfile = TranscriptionProfile(rawValue: defaults.string(forKey: Keys.profile) ?? "") ?? .maximumQuality
        languageMode = LanguageMode(rawValue: defaults.string(forKey: Keys.languageMode) ?? "") ?? .ukrainian
        diarizationEnabled = defaults.object(forKey: Keys.diarizationEnabled) as? Bool ?? true
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "gpt-4o-mini"

        let resolvedOutputFolderPath: String
        if let savedPath = defaults.string(forKey: Keys.outputFolder) {
            resolvedOutputFolderPath = savedPath
        } else {
            resolvedOutputFolderPath = Self.defaultOutputDirectory().path
            defaults.set(resolvedOutputFolderPath, forKey: Keys.outputFolder)
        }
        outputFolderPath = resolvedOutputFolderPath

        do {
            let storedKey = try Self.readOpenAIAPIKeyFromKeychain()
            hasOpenAIAPIKey = !(storedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        } catch {
            hasOpenAIAPIKey = false
        }

        ensureOutputFolderExists()
    }

    func outputFolderURL() -> URL {
        URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    func setOutputFolder(url: URL) {
        outputFolderPath = url.path
        ensureOutputFolderExists()
    }

    func ensureOutputFolderExists() {
        let url = outputFolderURL()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Keep app resilient if folder creation fails. Job processing will surface a concrete error.
            print("Failed to create output directory: \(error.localizedDescription)")
        }
    }

    func openAIAPIKey() -> String? {
        do {
            return try Self.readOpenAIAPIKeyFromKeychain()
        } catch {
            print("Failed to read OpenAI API key from Keychain: \(error.localizedDescription)")
            return nil
        }
    }

    func saveOpenAIAPIKey(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clearOpenAIAPIKey()
            return
        }

        try KeychainStore.save(service: SecretKeys.service, account: SecretKeys.account, value: trimmed)
        hasOpenAIAPIKey = true
    }

    func clearOpenAIAPIKey() throws {
        try KeychainStore.delete(service: SecretKeys.service, account: SecretKeys.account)
        hasOpenAIAPIKey = false
    }

    static func defaultOutputDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)

        return documents
            .appendingPathComponent("VukhoAI", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    private static func readOpenAIAPIKeyFromKeychain() throws -> String? {
        try KeychainStore.read(service: SecretKeys.service, account: SecretKeys.account)
    }
}
