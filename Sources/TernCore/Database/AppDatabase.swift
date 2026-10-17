import Foundation
import GRDB

/// The single SQLite file holding every account. The UI only ever reads from here.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif
        Schema.register(in: &migrator)
        try migrator.migrate(writer)
    }

    /// Opens (or creates) the database file. WAL lets the UI read while sync writes.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 8
        config.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA synchronous = NORMAL;
                PRAGMA temp_store = MEMORY;
                PRAGMA cache_size = -65536;
                PRAGMA mmap_size = 268435456;
                """)
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// An in-memory database for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    /// ~/Library/Application Support/Tern/<name>.sqlite
    public static func defaultURL(name: String = "Tern") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tern", isDirectory: true)
            .appendingPathComponent("\(name).sqlite")
    }
}
