import Foundation

struct VukhoAIPaths {
    let baseDirectory: URL
    let databaseURL: URL
    let normalizedAudioDirectory: URL
    let metadataDirectory: URL

    private static let brandedDirectoryName = "VukhoAI"
    private static let brandedDatabaseName = "vukhoai.sqlite"

    static func build() throws -> VukhoAIPaths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)

        let base = appSupport.appendingPathComponent(brandedDirectoryName, isDirectory: true)
        let normalized = base.appendingPathComponent("normalized", isDirectory: true)
        let metadata = base.appendingPathComponent("meta", isDirectory: true)
        let database = base.appendingPathComponent(brandedDatabaseName, isDirectory: false)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: normalized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

        return VukhoAIPaths(
            baseDirectory: base,
            databaseURL: database,
            normalizedAudioDirectory: normalized,
            metadataDirectory: metadata
        )
    }
}
