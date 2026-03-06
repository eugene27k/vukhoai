import Foundation

enum JobStatus: String, Codable, CaseIterable {
    case queued
    case processing
    case done
    case failed

    var displayName: String {
        rawValue.capitalized
    }
}

enum TranscriptionProfile: String, Codable, CaseIterable, Identifiable {
    case maximumQuality
    case balanced
    case fastEconomy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .maximumQuality:
            return "Maximum Quality"
        case .balanced:
            return "Balanced"
        case .fastEconomy:
            return "Fast / Economy"
        }
    }

    var modelName: String {
        switch self {
        case .maximumQuality:
            return "large-v3"
        case .balanced:
            return "medium"
        case .fastEconomy:
            return "small"
        }
    }

    var pythonFlag: String {
        switch self {
        case .maximumQuality:
            return "max"
        case .balanced:
            return "balanced"
        case .fastEconomy:
            return "fast"
        }
    }
}

enum LanguageMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case ukrainian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .ukrainian:
            return "Force Ukrainian"
        }
    }

    var pythonFlag: String {
        switch self {
        case .auto:
            return "auto"
        case .ukrainian:
            return "uk"
        }
    }
}

struct ImportJob: Identifiable, Codable {
    let id: String
    var inputPath: String
    var inputFilename: String
    var normalizedAudioPath: String?
    var status: JobStatus
    var createdAt: Date
    var durationSeconds: Double?
    var profile: TranscriptionProfile
    var languageMode: LanguageMode
    var diarizationEnabled: Bool
    var outputTXTPath: String?
    var metaJSONPath: String?
    var errorMessage: String?
    var protocolPath: String?
    var protocolErrorMessage: String?
}

struct PreparedAudio {
    let url: URL
    let durationSeconds: Double
}

struct JobProgressSnapshot {
    var percent: Double
    var etaSeconds: Double?
    var stage: String
    var updatedAt: Date

    static func preparing() -> JobProgressSnapshot {
        JobProgressSnapshot(percent: 1, etaSeconds: nil, stage: "Preparing audio", updatedAt: Date())
    }
}
