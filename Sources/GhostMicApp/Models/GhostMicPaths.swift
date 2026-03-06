import Foundation

struct GhostMicPaths {
    let baseDirectory: URL
    let databaseURL: URL
    let normalizedAudioDirectory: URL
    let metadataDirectory: URL

    static func build() throws -> GhostMicPaths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        let base = appSupport.appendingPathComponent("GhostMic", isDirectory: true)
        let normalized = base.appendingPathComponent("normalized", isDirectory: true)
        let metadata = base.appendingPathComponent("meta", isDirectory: true)
        let database = base.appendingPathComponent("ghostmic.sqlite", isDirectory: false)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        return GhostMicPaths(
            baseDirectory: base,
            databaseURL: database,
            normalizedAudioDirectory: normalized,
            metadataDirectory: metadata
        )
    }
}
