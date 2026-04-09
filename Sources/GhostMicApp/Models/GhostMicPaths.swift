import Foundation

struct GhostMicPaths {
    let baseDirectory: URL
    let databaseURL: URL
    let normalizedAudioDirectory: URL
    let metadataDirectory: URL

    private static let brandedDirectoryName = "VukhoAI"
    private static let legacyDirectoryName = "GhostMic"
    private static let brandedDatabaseName = "vukhoai.sqlite"
    private static let legacyDatabaseName = "ghostmic.sqlite"

    static func build() throws -> GhostMicPaths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        try migrateLegacyStorageIfNeeded(appSupportDirectory: appSupport)

        let base = appSupport.appendingPathComponent(brandedDirectoryName, isDirectory: true)
        let normalized = base.appendingPathComponent("normalized", isDirectory: true)
        let metadata = base.appendingPathComponent("meta", isDirectory: true)
        let database = base.appendingPathComponent(brandedDatabaseName, isDirectory: false)

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

    private static func migrateLegacyStorageIfNeeded(appSupportDirectory: URL) throws {
        let fileManager = FileManager.default
        let legacyBase = appSupportDirectory.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let brandedBase = appSupportDirectory.appendingPathComponent(brandedDirectoryName, isDirectory: true)

        if !fileManager.fileExists(atPath: brandedBase.path),
           fileManager.fileExists(atPath: legacyBase.path) {
            try fileManager.moveItem(at: legacyBase, to: brandedBase)
        }

        let legacyDatabase = brandedBase.appendingPathComponent(legacyDatabaseName, isDirectory: false)
        let brandedDatabase = brandedBase.appendingPathComponent(brandedDatabaseName, isDirectory: false)

        if !fileManager.fileExists(atPath: brandedDatabase.path),
           fileManager.fileExists(atPath: legacyDatabase.path) {
            try fileManager.moveItem(at: legacyDatabase, to: brandedDatabase)
        }
    }
}
