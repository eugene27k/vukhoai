import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class JobRepository {
    enum RepositoryError: Error {
        case openDatabase(String)
        case prepare(String)
        case step(String)
    }

    private let queue = DispatchQueue(label: "VukhoAI.JobRepository")
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        try queue.sync {
            try openDatabase(at: databaseURL)
            try createSchema()
        }
    }

    deinit {
        queue.sync {
            if db != nil {
                sqlite3_close(db)
            }
        }
    }

    func fetchAllJobs() throws -> [ImportJob] {
        try queue.sync {
            let sql = """
            SELECT id, input_path, input_filename, normalized_audio_path, status, created_at, duration_seconds,
                   profile, language_mode, diarization_enabled, output_txt_path, meta_json_path, error_message,
                   protocol_path, protocol_error_message
            FROM jobs
            ORDER BY created_at DESC;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            var jobs: [ImportJob] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                jobs.append(job(from: statement))
            }
            return jobs
        }
    }

    func insert(job: ImportJob) throws {
        try queue.sync {
            let sql = """
            INSERT INTO jobs (
                id, input_path, input_filename, normalized_audio_path, status, created_at, duration_seconds,
                profile, language_mode, diarization_enabled, output_txt_path, meta_json_path, error_message,
                protocol_path, protocol_error_message
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: job.id)
            bind(statement, index: 2, value: job.inputPath)
            bind(statement, index: 3, value: job.inputFilename)
            bind(statement, index: 4, value: job.normalizedAudioPath)
            bind(statement, index: 5, value: job.status.rawValue)
            sqlite3_bind_double(statement, 6, job.createdAt.timeIntervalSince1970)
            if let duration = job.durationSeconds {
                sqlite3_bind_double(statement, 7, duration)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            bind(statement, index: 8, value: job.profile.rawValue)
            bind(statement, index: 9, value: job.languageMode.rawValue)
            sqlite3_bind_int(statement, 10, job.diarizationEnabled ? 1 : 0)
            bind(statement, index: 11, value: job.outputTXTPath)
            bind(statement, index: 12, value: job.metaJSONPath)
            bind(statement, index: 13, value: job.errorMessage)
            bind(statement, index: 14, value: job.protocolPath)
            bind(statement, index: 15, value: job.protocolErrorMessage)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func claimNextQueuedJob() throws -> ImportJob? {
        try queue.sync {
            let selectSQL = """
            SELECT id, input_path, input_filename, normalized_audio_path, status, created_at, duration_seconds,
                   profile, language_mode, diarization_enabled, output_txt_path, meta_json_path, error_message,
                   protocol_path, protocol_error_message
            FROM jobs
            WHERE status = ?
            ORDER BY created_at ASC
            LIMIT 1;
            """

            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(selectStmt) }

            bind(selectStmt, index: 1, value: JobStatus.queued.rawValue)
            guard sqlite3_step(selectStmt) == SQLITE_ROW else {
                return nil
            }

            let job = job(from: selectStmt)

            let updateSQL = "UPDATE jobs SET status = ?, error_message = NULL WHERE id = ?;"
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(updateStmt) }

            bind(updateStmt, index: 1, value: JobStatus.processing.rawValue)
            bind(updateStmt, index: 2, value: job.id)

            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }

            var processingJob = job
            processingJob.status = .processing
            processingJob.errorMessage = nil
            return processingJob
        }
    }

    func updatePreparedAudio(jobID: String, normalizedPath: String, durationSeconds: Double) throws {
        try queue.sync {
            let sql = """
            UPDATE jobs
            SET normalized_audio_path = ?, duration_seconds = ?
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: normalizedPath)
            sqlite3_bind_double(statement, 2, durationSeconds)
            bind(statement, index: 3, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func markDone(jobID: String, outputTXTPath: String, metaJSONPath: String?) throws {
        try queue.sync {
            let sql = """
            UPDATE jobs
            SET status = ?, output_txt_path = ?, meta_json_path = ?, error_message = NULL
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: JobStatus.done.rawValue)
            bind(statement, index: 2, value: outputTXTPath)
            bind(statement, index: 3, value: metaJSONPath)
            bind(statement, index: 4, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func markFailed(jobID: String, errorMessage: String) throws {
        try queue.sync {
            let sql = "UPDATE jobs SET status = ?, error_message = ? WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: JobStatus.failed.rawValue)
            bind(statement, index: 2, value: errorMessage)
            bind(statement, index: 3, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func updateProtocolReady(jobID: String, protocolPath: String) throws {
        try queue.sync {
            let sql = "UPDATE jobs SET protocol_path = ?, protocol_error_message = NULL WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: protocolPath)
            bind(statement, index: 2, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func updateProtocolFailed(jobID: String, errorMessage: String?) throws {
        try queue.sync {
            let sql = "UPDATE jobs SET protocol_error_message = ?, protocol_path = CASE WHEN ? IS NULL THEN protocol_path ELSE NULL END WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: errorMessage)
            bind(statement, index: 2, value: errorMessage)
            bind(statement, index: 3, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func cancel(jobID: String, reason: String) throws {
        try queue.sync {
            let sql = "UPDATE jobs SET status = ?, error_message = ? WHERE id = ? AND status IN (?, ?);"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: JobStatus.failed.rawValue)
            bind(statement, index: 2, value: reason)
            bind(statement, index: 3, value: jobID)
            bind(statement, index: 4, value: JobStatus.queued.rawValue)
            bind(statement, index: 5, value: JobStatus.processing.rawValue)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func retry(jobID: String) throws {
        try queue.sync {
            let sql = "UPDATE jobs SET status = ?, error_message = NULL WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: JobStatus.queued.rawValue)
            bind(statement, index: 2, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    func delete(jobID: String) throws {
        try queue.sync {
            let sql = "DELETE FROM jobs WHERE id = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw RepositoryError.prepare(lastError())
            }
            defer { sqlite3_finalize(statement) }

            bind(statement, index: 1, value: jobID)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw RepositoryError.step(lastError())
            }
        }
    }

    private func openDatabase(at url: URL) throws {
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw RepositoryError.openDatabase(lastError())
        }
    }

    private func createSchema() throws {
        let schemaSQL = """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            input_path TEXT NOT NULL,
            input_filename TEXT NOT NULL,
            normalized_audio_path TEXT,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            duration_seconds REAL,
            profile TEXT NOT NULL,
            language_mode TEXT NOT NULL,
            diarization_enabled INTEGER NOT NULL,
            output_txt_path TEXT,
            meta_json_path TEXT,
            error_message TEXT,
            protocol_path TEXT,
            protocol_error_message TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_jobs_status_created_at
        ON jobs(status, created_at);
        """

        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else {
            throw RepositoryError.step(lastError())
        }

        try ensureColumnExists(name: "protocol_path", definition: "TEXT")
        try ensureColumnExists(name: "protocol_error_message", definition: "TEXT")
    }

    private func ensureColumnExists(name: String, definition: String) throws {
        let columns = try existingColumns()
        guard !columns.contains(name) else {
            return
        }

        let sql = "ALTER TABLE jobs ADD COLUMN \(name) \(definition);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw RepositoryError.step(lastError())
        }
    }

    private func existingColumns() throws -> Set<String> {
        let sql = "PRAGMA table_info(jobs);"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryError.prepare(lastError())
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let columnName = stringColumn(statement, index: 1) {
                columns.insert(columnName)
            }
        }
        return columns
    }

    private func job(from statement: OpaquePointer?) -> ImportJob {
        ImportJob(
            id: stringColumn(statement, index: 0) ?? UUID().uuidString,
            inputPath: stringColumn(statement, index: 1) ?? "",
            inputFilename: stringColumn(statement, index: 2) ?? "",
            normalizedAudioPath: stringColumn(statement, index: 3),
            status: JobStatus(rawValue: stringColumn(statement, index: 4) ?? "queued") ?? .queued,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            durationSeconds: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 6),
            profile: TranscriptionProfile(rawValue: stringColumn(statement, index: 7) ?? "maximumQuality") ?? .maximumQuality,
            languageMode: LanguageMode(rawValue: stringColumn(statement, index: 8) ?? "ukrainian") ?? .ukrainian,
            diarizationEnabled: sqlite3_column_int(statement, 9) == 1,
            outputTXTPath: stringColumn(statement, index: 10),
            metaJSONPath: stringColumn(statement, index: 11),
            errorMessage: stringColumn(statement, index: 12),
            protocolPath: stringColumn(statement, index: 13),
            protocolErrorMessage: stringColumn(statement, index: 14)
        )
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, sqliteTransient)
    }

    private func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func lastError() -> String {
        guard let message = sqlite3_errmsg(db) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }
}
