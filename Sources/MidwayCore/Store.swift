import CryptoKit
import Foundation
import GRDB

public struct Account: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var email: String
    public var imapHost: String
    public var imapPort: Int
    public var kind: Kind

    public enum Kind: String, Codable, Sendable {
        /// App password over LOGIN (Fastmail).
        case password
        /// OAuth refresh token, XOAUTH2, [Gmail]/All Mail with labels.
        case google
    }

    public init(email: String, imapHost: String, imapPort: Int = 993, kind: Kind = .password) {
        self.email = email
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.kind = kind
    }

    public static func gmail(_ email: String) -> Account {
        Account(email: email, imapHost: "imap.gmail.com", kind: .google)
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
    public var gmMsgId: Int64?
    public var gmThrId: Int64?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum Label {
    /// The label every view of "Inbox" is built on, for IMAP folders and Gmail alike.
    public static let inbox = "\\Inbox"
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
        m.registerMigration("v2-gmail") { db in
            try db.alter(table: "account") { t in t.add(column: "kind", .text).notNull().defaults(to: "password") }
            try db.alter(table: "message") { t in
                t.add(column: "gmMsgId", .integer)
                t.add(column: "gmThrId", .integer)
            }
            // Views are label queries: Fastmail's INBOX is the \Inbox label, Gmail's come from X-GM-LABELS.
            try db.create(table: "label") { t in
                t.column("messageId", .integer).notNull().references("message", onDelete: .cascade)
                t.column("name", .text).notNull().indexed()
                t.primaryKey(["messageId", "name"])
            }
            try db.execute(sql: "INSERT INTO label (messageId, name) SELECT id, ? FROM message WHERE mailbox = 'INBOX'", arguments: [Label.inbox])
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

    /// What the server says about one message, from a FETCH.
    public struct ServerState: Sendable {
        public var seen: Bool
        public var labels: [String]
        public var gmMsgId: Int64?
        public var gmThrId: Int64?

        public init(seen: Bool, labels: [String], gmMsgId: Int64? = nil, gmThrId: Int64? = nil) {
            self.seen = seen
            self.labels = labels
            self.gmMsgId = gmMsgId
            self.gmThrId = gmThrId
        }
    }

    public func insert(raw: Data, uid: Int64, state: ServerState, account: Int64, mailbox: String) throws {
        let hash = try writeBlob(raw)
        let p = MIME.parse(raw)
        try db.write { db in
            var m = Message(
                accountId: account, mailbox: mailbox, uid: uid, messageId: p.messageId,
                fromName: p.from.name, fromAddr: p.from.address, toAddr: p.to.address,
                subject: p.subject, date: p.date ?? .now, preview: p.preview,
                seen: state.seen, seenDirty: false, blob: hash, gmMsgId: state.gmMsgId, gmThrId: state.gmThrId)
            try m.insert(db, onConflict: .ignore)
            if let id = m.id { try setLabels(state.labels, message: id, db) }
        }
    }

    /// Server flags and labels win, except seen on rows with a local change still waiting to be stored.
    public func update(_ states: [Int64: ServerState], account: Int64, mailbox: String) throws {
        try db.write { db in
            for (uid, s) in states {
                guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE accountId = ? AND mailbox = ? AND uid = ?", arguments: [account, mailbox, uid]) else { continue }
                try db.execute(sql: "UPDATE message SET seen = ? WHERE id = ? AND seenDirty = 0", arguments: [s.seen, id])
                try setLabels(s.labels, message: id, db)
            }
        }
    }

    func setLabels(_ labels: [String], message: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM label WHERE messageId = ?", arguments: [message])
        for name in Set(labels) {
            try db.execute(sql: "INSERT INTO label (messageId, name) VALUES (?, ?)", arguments: [message, name])
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
