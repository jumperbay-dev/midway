import CryptoKit
import Foundation
import GRDB

public struct Account: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var email: String
    public var imapHost: String
    public var imapPort: Int

    public init(email: String, imapHost: String, imapPort: Int = 993) {
        self.email = email
        self.imapHost = imapHost
        self.imapPort = imapPort
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct Message: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var mailbox: String
    public var uid: Int64
    public var messageId: String?
    public var fromName: String
    public var fromAddr: String
    public var toAddr: String
    public var subject: String
    public var date: Date
    public var preview: String
    public var seen: Bool
    /// Seen changed locally and not yet stored on the server.
    public var seenDirty: Bool
    public var blob: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One SQLite database (GRDB, WAL) plus content-addressed raw messages, as in the design doc's Storage section.
public final class Store: Sendable {
    public let db: DatabasePool
    let blobs: URL

    public static func open(at dir: URL) throws -> Store {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try DatabasePool(path: dir.appending(path: "midway.sqlite").path)
        try migrator.migrate(db)
        return Store(db: db, blobs: dir.appending(path: "messages"))
    }

    /// `MIDWAY_HOME` points a dev run at a throwaway store.
    public static var defaultDirectory: URL {
        ProcessInfo.processInfo.environment["MIDWAY_HOME"].map { URL(filePath: $0) }
            ?? URL.applicationSupportDirectory.appending(path: "midway")
    }

    init(db: DatabasePool, blobs: URL) {
        self.db = db
        self.blobs = blobs
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email", .text).notNull().unique()
                t.column("imapHost", .text).notNull()
                t.column("imapPort", .integer).notNull()
            }
            try db.create(table: "mailbox") { t in
                t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("uidValidity", .integer).notNull()
                t.primaryKey(["accountId", "name"])
            }
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
                t.column("mailbox", .text).notNull()
                t.column("uid", .integer).notNull()
                t.column("messageId", .text)
                t.column("fromName", .text).notNull()
                t.column("fromAddr", .text).notNull()
                t.column("toAddr", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("date", .datetime).notNull().indexed()
                t.column("preview", .text).notNull()
                t.column("seen", .boolean).notNull()
                t.column("seenDirty", .boolean).notNull().defaults(to: false)
                t.column("blob", .text).notNull()
                t.uniqueKey(["accountId", "mailbox", "uid"])
            }
        }
        return m
    }

    // MARK: accounts

    public func accounts() throws -> [Account] {
        try db.read { try Account.fetchAll($0) }
    }

    @discardableResult
    public func add(_ account: Account) throws -> Account {
        try db.write { db in
            var a = account
            try a.insert(db)
            return a
        }
    }

    // MARK: sync

    /// Returns the UIDs already stored. A changed UIDVALIDITY drops the mailbox's rows first.
    public func prepareMailbox(account: Int64, name: String, uidValidity: Int64) throws -> Set<Int64> {
        try db.write { db in
            let old = try Int64.fetchOne(db, sql: "SELECT uidValidity FROM mailbox WHERE accountId = ? AND name = ?", arguments: [account, name])
            if old != uidValidity {
                // ponytail: rows are re-downloaded on UIDVALIDITY reset; re-matching by stable key comes with tags (M5)
                try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND mailbox = ?", arguments: [account, name])
                try db.execute(sql: "INSERT OR REPLACE INTO mailbox (accountId, name, uidValidity) VALUES (?, ?, ?)", arguments: [account, name, uidValidity])
            }
            return Set(try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE accountId = ? AND mailbox = ?", arguments: [account, name]))
        }
    }

    public func insert(raw: Data, uid: Int64, seen: Bool, account: Int64, mailbox: String) throws {
        let hash = try writeBlob(raw)
        let p = MIME.parse(raw)
        try db.write { db in
            var m = Message(
                accountId: account, mailbox: mailbox, uid: uid, messageId: p.messageId,
                fromName: p.from.name, fromAddr: p.from.address, toAddr: p.to.address,
                subject: p.subject, date: p.date ?? .now, preview: p.preview,
                seen: seen, seenDirty: false, blob: hash)
            try m.insert(db, onConflict: .ignore)
        }
    }

    /// Server flags win, except for rows with a local change still waiting to be stored.
    public func updateSeen(_ seen: [Int64: Bool], account: Int64, mailbox: String) throws {
        try db.write { db in
            for (uid, s) in seen {
                try db.execute(sql: "UPDATE message SET seen = ? WHERE accountId = ? AND mailbox = ? AND uid = ? AND seenDirty = 0", arguments: [s, account, mailbox, uid])
            }
        }
    }

    public func markSeen(_ id: Int64) throws {
        try db.write { try $0.execute(sql: "UPDATE message SET seen = 1, seenDirty = 1 WHERE id = ? AND seen = 0", arguments: [id]) }
    }

    public func dirtySeen(account: Int64, mailbox: String) throws -> [Int64] {
        try db.read { try Int64.fetchAll($0, sql: "SELECT uid FROM message WHERE accountId = ? AND mailbox = ? AND seenDirty = 1", arguments: [account, mailbox]) }
    }

    public func clearDirty(_ uids: [Int64], account: Int64, mailbox: String) throws {
        try db.write { db in
            for uid in uids {
                try db.execute(sql: "UPDATE message SET seenDirty = 0 WHERE accountId = ? AND mailbox = ? AND uid = ?", arguments: [account, mailbox, uid])
            }
        }
    }

    // MARK: blobs

    func blobURL(_ hash: String) -> URL {
        let h = Array(hash)
        return blobs.appending(path: "\(String(h[0..<2]))/\(String(h[2..<4]))/\(hash).eml")
    }

    /// Written once, never edited: the same message in two folders is stored once.
    func writeBlob(_ raw: Data) throws -> String {
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let url = blobURL(hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try raw.write(to: url, options: [.atomic, .completeFileProtection])
        }
        return hash
    }

    public func raw(_ message: Message) throws -> Data {
        try Data(contentsOf: blobURL(message.blob))
    }
}
