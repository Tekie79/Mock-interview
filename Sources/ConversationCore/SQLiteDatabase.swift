import CSQLite
import Foundation

public enum StorageFailure: Error, Equatable, Sendable {
    case database(Int32)
    case invalidRecord
    case unsupportedFormat
    case emptyDocument
    case documentTooLarge
}

final class SQLiteDatabase {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                                     nil)
        guard let opened, result == SQLITE_OK else {
            if let opened { sqlite3_close(opened) }
            throw StorageFailure.database(result)
        }
        handle = opened
        sqlite3_busy_timeout(handle, 2_500)
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw StorageFailure.database(status) }
    }

    func write(_ sql: String, _ values: [String]) throws {
        _ = try query(sql, values) { _ in () }
    }

    func query<T>(_ sql: String, _ values: [String] = [],
                  read: (OpaquePointer) throws -> T) throws -> [T] {
        var prepared: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard status == SQLITE_OK, let statement = prepared else { throw StorageFailure.database(status) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else {
            throw StorageFailure.invalidRecord
        }
        for (index, value) in values.enumerated() {
            guard value.utf8.count <= Int32.max else { throw StorageFailure.invalidRecord }
            let bind = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient)
            }
            guard bind == SQLITE_OK else { throw StorageFailure.database(bind) }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(try read(statement))
            case SQLITE_DONE: return rows
            case let failure: throw StorageFailure.database(failure)
            }
        }
    }

    func transaction<T>(_ work: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column) else { return "" }
        let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column)))
        return String(decoding: bytes, as: UTF8.self)
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from statement: OpaquePointer, column: Int32 = 0) throws -> T {
        try JSONDecoder().decode(type, from: Data(text(statement, column).utf8))
    }

    static func keywords(in input: String) -> String {
        var seen = Set<String>()
        return input.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 2 && !stopWords.contains(String($0)) && seen.insert(String($0)).inserted }
            .prefix(32).map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "be", "can", "could", "did", "do", "for", "how", "in", "is",
        "it", "me", "of", "on", "or", "the", "to", "was", "were", "what", "with", "would", "you", "your"
    ]
}
