import AVFoundation
import Foundation

enum AudioPreprocessorError: LocalizedError {
    case invalidAsset
    case missingAudioTrack
    case exportSessionUnavailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAsset:
            return "Input file cannot be read as media asset."
        case .missingAudioTrack:
            return "No audio track found in MP4 file."
        case .exportSessionUnavailable:
            return "Unable to create audio export session for MP4."
        case let .exportFailed(message):
            return "Audio extraction failed: \(message)"
        }
    }
}

enum AudioPreprocessor {
    static func prepare(inputURL: URL, jobID: String, normalizedDirectory: URL) async throws -> PreparedAudio {
        let ext = inputURL.pathExtension.lowercased()
        switch ext {
        case "m4a":
            let duration = try await mediaDuration(url: inputURL)
            return PreparedAudio(url: inputURL, durationSeconds: duration)
        case "mp4":
            let normalized = normalizedDirectory.appendingPathComponent("\(jobID).m4a")
            let duration = try await extractAudio(from: inputURL, to: normalized)
            return PreparedAudio(url: normalized, durationSeconds: duration)
        default:
            throw JobStore.ImportError.unsupportedFormat
        }
    }

    static func mediaDuration(url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private static func extractAudio(from inputURL: URL, to outputURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw AudioPreprocessorError.missingAudioTrack
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioPreprocessorError.exportSessionUnavailable
        }

        try? FileManager.default.removeItem(at: outputURL)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: AudioPreprocessorError.exportFailed(exportSession.error?.localizedDescription ?? "Unknown AVFoundation export error"))
                case .cancelled:
                    continuation.resume(throwing: AudioPreprocessorError.exportFailed("Export was cancelled"))
                default:
                    continuation.resume(throwing: AudioPreprocessorError.exportFailed("Unexpected export status \(exportSession.status.rawValue)"))
                }
            }
        }

        let duration = try await mediaDuration(url: outputURL)
        return duration
    }
}
