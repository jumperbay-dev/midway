import CryptoKit
import Foundation
import GRDB

public struct Account: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var email: String
    public var imapHost: String
    public var imapPort: Int
    public var kind: Kind
    /// Whether this account's mail may go to an AI engine. Off until the user turns it on.
    public var ai = false

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

    /// imap.fastmail.com → smtp.fastmail.com, imap.gmail.com → smtp.gmail.com.
    public var smtpHost: String {
        imapHost.hasPrefix("imap.") ? "smtp." + imapHost.dropFirst(5) : imapHost
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
    public var flagged: Bool
    public var blob: String
    public var gmMsgId: Int64?
    public var gmThrId: Int64?
    /// Message-ID, or the blob hash without one: what tags hang on.
    public var key: String?
    /// Which of your addresses it reached (Provenance.via).
    public var via: String?
    public var listId: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum Label {
    /// The label every view of "Inbox" is built on, for IMAP folders and Gmail alike.
    public static let inbox = "\\Inbox"
    public static let trash = "\\Trash"
}

/// A message action. Applied to the store at once, sent to the server by the account's sync.
/// Each one states an end state ("seen = true"), so replaying it is harmless.
public enum OpKind: String, Codable, Sendable {
    case seen, flagged, archive, trash
}

public struct PendingOp: Sendable, Equatable {
    public var id: Int64
    public var uid: Int64
    public var kind: OpKind
    public var value: Bool
}

/// Local-only triage state, never synced: Reply later, Set aside and Snooze.
public struct Pile: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public var messageId: Int64
    public var replyLater = false
    public var setAside = false
    public var snoozedUntil: Date?
    /// Bring back early if someone replies in the thread.
    public var wakeOnReply = true

    public init(messageId: Int64) { self.messageId = messageId }
    var isEmpty: Bool { !replyLater && !setAside && snoozedUntil == nil }
}

public struct Contact: Codable, Hashable, Sendable, FetchableRecord {
    public var address: String
    public var name: String
    public var lastSeen: Date
    public var sent: Int
    public var received: Int
}

public struct Draft: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var accountId: Int64
    public var toList = ""
    public var ccList = ""
    public var bccList = ""
    public var subject = ""
    /// The composer's rich text as RTF; HTML and plain text are generated at send.
    public var rtf = Data()
    public var inReplyTo: String?
    public var refs: String?
    public var updatedAt = Date.now

    public init(accountId: Int64) { self.accountId = accountId }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct OutboxItem: Codable, Hashable, Sendable, Identifiable, FetchableRecord {
    public var id: Int64
    public var draftId: Int64
    public var accountId: Int64
    public var raw: Data
    /// Envelope recipients, one per line (To, Cc and Bcc).
    public var recipients: String
    public var sendAt: Date
    public var attempts: Int
    public var error: String?
}

/// One SQLite database (GRDB, WAL) plus content-addressed raw messages, as in the design doc's Storage section.
public final class Store: Sendable {
    public let db: DatabasePool
    let blobs: URL

    public static func open(at dir: URL) throws -> Store {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try DatabasePool(path: dir.appending(path: "midway.sqlite").path)
        let blobs = dir.appending(path: "messages")
        try migrator(blobs: blobs).migrate(db)
        return Store(db: db, blobs: blobs)
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

    static func migrator(blobs: URL) -> DatabaseMigrator {
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
        m.registerMigration("v3-daily") { db in
            try db.alter(table: "message") { t in t.add(column: "flagged", .boolean).notNull().defaults(to: false) }
            // The offline queue. One row per message and kind: a newer opposite action cancels it.
            try db.create(table: "op") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer).notNull().references("message", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("value", .boolean).notNull()
                t.column("prior", .text)  // labels before archive or trash, restored on undo
                t.column("notBefore", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["messageId", "kind"])
            }
            try db.execute(sql: "INSERT INTO op (messageId, kind, value, notBefore) SELECT id, 'seen', 1, ? FROM message WHERE seenDirty = 1", arguments: [Date.now])
            try db.alter(table: "message") { t in t.drop(column: "seenDirty") }

            try db.execute(sql: "CREATE VIRTUAL TABLE message_fts USING fts5(subject, people, body, tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3')")
            try db.execute(sql: "CREATE TRIGGER message_fts_delete AFTER DELETE ON message BEGIN DELETE FROM message_fts WHERE rowid = old.id; END")
            try db.create(table: "contact") { t in
                t.column("address", .text).primaryKey().collate(.nocase)
                t.column("name", .text).notNull()
                t.column("lastSeen", .datetime).notNull()
                t.column("sent", .integer).notNull()
                t.column("received", .integer).notNull()
            }
            try db.create(table: "draft") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
                t.column("toList", .text).notNull()
                t.column("ccList", .text).notNull()
                t.column("bccList", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("rtf", .blob).notNull()
                t.column("inReplyTo", .text)
                t.column("refs", .text)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "outbox") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("draftId", .integer).notNull().unique().references("draft", onDelete: .cascade)
                t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
                t.column("raw", .blob).notNull()
                t.column("recipients", .text).notNull()
                t.column("sendAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("error", .text)
            }
            // Index what is already stored.
            let rows = try Row.fetchAll(db, sql: "SELECT message.id, message.blob, message.date, account.email FROM message JOIN account ON account.id = message.accountId")
            for r in rows {
                let hash: String = r["blob"]
                guard let raw = try? Data(contentsOf: blobURL(blobs, hash)) else { continue }
                try index(r["id"], MIME.parse(raw), account: r["email"], date: r["date"], db)
            }
        }
        m.registerMigration("v4-triage") { db in
            try db.create(table: "pile") { t in
                t.primaryKey("messageId", .integer).references("message", onDelete: .cascade)
                t.column("replyLater", .boolean).notNull().defaults(to: false)
                t.column("setAside", .boolean).notNull().defaults(to: false)
                t.column("snoozedUntil", .datetime).indexed()
                t.column("wakeOnReply", .boolean).notNull().defaults(to: true)
            }
        }
        m.registerMigration("v5-tags") { db in
            try db.alter(table: "message") { t in
                t.add(column: "key", .text)
                t.add(column: "via", .text)
                t.add(column: "listId", .text)
            }
            try db.create(index: "message_on_key", on: "message", columns: ["key"])
            try db.create(index: "message_on_via", on: "message", columns: ["via"])
            try db.create(index: "message_on_fromAddr", on: "message", columns: ["fromAddr"])
            try db.create(table: "tag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("colour", .integer).notNull()
            }
            try db.create(table: "tag_link") { t in
                t.column("key", .text).notNull()
                t.column("tagId", .integer).notNull().references("tag", onDelete: .cascade)
                t.column("source", .text).notNull()  // manual, or rule:<id>
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["key", "tagId"])
            }
            try db.create(table: "tag_rule") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tagId", .integer).references("tag", onDelete: .cascade)
                t.column("query", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "screener") { t in
                t.primaryKey("address", .text).collate(.nocase)
                t.column("decision", .text).notNull()  // allow, block
            }
            try db.execute(sql: "UPDATE message SET key = COALESCE(messageId, blob)")
            let rows = try Row.fetchAll(db, sql: "SELECT message.id, message.blob, account.email FROM message JOIN account ON account.id = message.accountId")
            for r in rows {
                guard let raw = try? Data(contentsOf: blobURL(blobs, r["blob"])) else { continue }
                let p = MIME.parse(raw)
                try db.execute(sql: "UPDATE message SET via = ?, listId = ? WHERE id = ?",
                               arguments: [Provenance.via(p, account: r["email"]), Provenance.listId(p.listId), r["id"] as Int64])
            }
            // The Screener starts now: everyone who already wrote, and everyone you wrote to, is let through.
            try db.execute(sql: "INSERT OR IGNORE INTO screener (address, decision) SELECT DISTINCT fromAddr, 'allow' FROM message")
            try db.execute(sql: "INSERT OR IGNORE INTO screener (address, decision) SELECT address, 'allow' FROM contact WHERE sent > 0")
        }
        m.registerMigration("v6-quick") { db in
            try db.create(table: "quick_item") { t in
                t.column("messageId", .integer).notNull().references("message", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("label", .text).notNull()
                t.column("url", .text)
                t.column("date", .datetime).notNull().indexed()
                t.column("delivered", .boolean).notNull().defaults(to: false)
                t.primaryKey(["messageId", "kind", "value"])
            }
            // Oldest first, so a later "delivered" mail clears the parcels before it.
            for r in try Row.fetchAll(db, sql: "SELECT id, blob, date FROM message ORDER BY date") {
                guard let raw = try? Data(contentsOf: blobURL(blobs, r["blob"])) else { continue }
                try noteQuick(r["id"], MIME.parse(raw), date: r["date"], db)
            }
        }
        m.registerMigration("v7-ai") { db in try migrateAI(db) }
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
                // Rows are re-downloaded on UIDVALIDITY reset. Tags follow by Message-ID.
                // ponytail: piles are lost on a reset; key them by Message-ID too if that bites
                try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND mailbox = ?", arguments: [account, name])
                try db.execute(sql: "INSERT OR REPLACE INTO mailbox (accountId, name, uidValidity) VALUES (?, ?, ?)", arguments: [account, name, uidValidity])
            }
            return Set(try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE accountId = ? AND mailbox = ?", arguments: [account, name]))
        }
    }

    /// What the server says about one message, from a FETCH.
    public struct ServerState: Sendable {
        public var seen: Bool
        public var flagged: Bool
        public var labels: [String]
        public var gmMsgId: Int64?
        public var gmThrId: Int64?

        public init(seen: Bool, flagged: Bool = false, labels: [String], gmMsgId: Int64? = nil, gmThrId: Int64? = nil) {
            self.seen = seen
            self.flagged = flagged
            self.labels = labels
            self.gmMsgId = gmMsgId
            self.gmThrId = gmThrId
        }
    }

    public func insert(raw: Data, uid: Int64, state: ServerState, account: Int64, mailbox: String) throws {
        let hash = try writeBlob(raw)
        let p = MIME.parse(raw)
        try db.write { db in
            let email = try String.fetchOne(db, sql: "SELECT email FROM account WHERE id = ?", arguments: [account]) ?? ""
            var m = Message(
                accountId: account, mailbox: mailbox, uid: uid, messageId: p.messageId,
                fromName: p.from.name, fromAddr: p.from.address, toAddr: p.to.address,
                subject: p.subject, date: p.date ?? .now, preview: p.preview,
                seen: state.seen, flagged: state.flagged, blob: hash, gmMsgId: state.gmMsgId, gmThrId: state.gmThrId,
                key: p.messageId ?? hash, via: Provenance.via(p, account: email), listId: Provenance.listId(p.listId))
            try m.insert(db, onConflict: .ignore)
            guard let id = m.id, db.changesCount > 0 else { return }
            try Self.setLabels(state.labels, message: id, db)
            try Self.index(id, p, account: email, date: m.date, db)
            try Self.wakeSnoozed(answeredBy: p, thread: state.gmThrId, db)
            try Self.screenAndTag(id, from: p.from.address, account: email, db)
            try Self.noteQuick(id, p, date: m.date, db)
        }
    }

    /// A reply from someone else brings a snoozed message back now, if it asked for that.
    static func wakeSnoozed(answeredBy p: MIME.Parsed, thread: Int64?, _ db: Database) throws {
        let mine = Set(try String.fetchAll(db, sql: "SELECT lower(email) FROM account"))
        guard !mine.contains(p.from.address.lowercased()), !p.answers.isEmpty || thread != nil else { return }
        let ids = p.answers.isEmpty ? "NULL" : p.answers.map { _ in "?" }.joined(separator: ",")
        try db.execute(sql: """
            UPDATE pile SET snoozedUntil = ? WHERE wakeOnReply = 1 AND snoozedUntil > ? AND messageId IN
                (SELECT id FROM message WHERE messageId IN (\(ids)) OR (gmThrId IS NOT NULL AND gmThrId = ?))
            """, arguments: StatementArguments([Date.now, Date.now] + p.answers.map { $0 as (any DatabaseValueConvertible)? } + [thread]))
    }

    /// Server flags and labels win, except where a local action is still queued for that message.
    public func update(_ states: [Int64: ServerState], account: Int64, mailbox: String) throws {
        try db.write { db in
            for (uid, s) in states {
                guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE accountId = ? AND mailbox = ? AND uid = ?", arguments: [account, mailbox, uid]) else { continue }
                let queued = Set(try String.fetchAll(db, sql: "SELECT kind FROM op WHERE messageId = ?", arguments: [id]))
                if !queued.contains("seen") { try db.execute(sql: "UPDATE message SET seen = ? WHERE id = ?", arguments: [s.seen, id]) }
                if !queued.contains("flagged") { try db.execute(sql: "UPDATE message SET flagged = ? WHERE id = ?", arguments: [s.flagged, id]) }
                if !queued.contains("archive") && !queued.contains("trash") { try Self.setLabels(s.labels, message: id, db) }
            }
        }
    }

    /// Drops rows whose UID the server no longer has, among UIDs >= `from`.
    public func removeMissing(account: Int64, mailbox: String, present: Set<Int64>, from: Int64) throws {
        try db.write { db in
            let local = try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE accountId = ? AND mailbox = ? AND uid >= ?", arguments: [account, mailbox, from])
            for uid in local where !present.contains(uid) {
                try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND mailbox = ? AND uid = ?", arguments: [account, mailbox, uid])
            }
        }
    }

    public func messageIds(account: Int64, mailbox: String, uids: [Int64]) throws -> [Int64] {
        try db.read { db in
            try uids.compactMap { try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE accountId = ? AND mailbox = ? AND uid = ?", arguments: [account, mailbox, $0]) }
        }
    }

    static func setLabels(_ labels: [String], message: Int64, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM label WHERE messageId = ?", arguments: [message])
        for name in Set(labels) {
            try db.execute(sql: "INSERT INTO label (messageId, name) VALUES (?, ?)", arguments: [message, name])
        }
    }

    // MARK: offline queue

    /// Applies an action locally and queues it for the server. An opposite action still in the queue
    /// cancels it instead (archive, then undo), restoring the labels it changed.
    /// `delay` holds archive and trash back so undo can catch them before the server does.
    public func apply(_ kind: OpKind, _ value: Bool, to id: Int64, delay: TimeInterval = 0) throws {
        try db.write { try Self.queue(kind, value, to: id, delay: delay, $0) }
    }

    static func queue(_ kind: OpKind, _ value: Bool, to id: Int64, delay: TimeInterval, _ db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT id, value, prior FROM op WHERE messageId = ? AND kind = ?", arguments: [id, kind.rawValue]) {
            guard row["value"] as Bool != value else { return }
            try db.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [row["id"] as Int64])
            switch kind {
            case .seen, .flagged: try db.execute(sql: "UPDATE message SET \(kind.rawValue) = ? WHERE id = ?", arguments: [value, id])
            case .archive, .trash:
                let prior: String? = row["prior"]
                try Self.setLabels(prior.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [], message: id, db)
            }
            return
        }
        let labels = try String.fetchAll(db, sql: "SELECT name FROM label WHERE messageId = ?", arguments: [id])
        var prior: String?
        switch kind {
        case .seen, .flagged:
            guard try Bool.fetchOne(db, sql: "SELECT \(kind.rawValue) FROM message WHERE id = ?", arguments: [id]) != value else { return }
            try db.execute(sql: "UPDATE message SET \(kind.rawValue) = ? WHERE id = ?", arguments: [value, id])
        case .archive:
            prior = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
            try Self.setLabels(value ? labels.filter { $0 != Label.inbox } : labels + [Label.inbox], message: id, db)
        case .trash:
            prior = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
            try Self.setLabels(value ? [Label.trash] : labels.filter { $0 != Label.trash } + [Label.inbox], message: id, db)
        }
        try db.execute(
            sql: "INSERT INTO op (messageId, kind, value, prior, notBefore) VALUES (?, ?, ?, ?, ?)",
            arguments: [id, kind.rawValue, value, prior, Date.now.addingTimeInterval(delay)])
    }

    /// Due ops for one mailbox, oldest first.
    public func pendingOps(account: Int64, mailbox: String) throws -> [PendingOp] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT op.id, message.uid, op.kind, op.value FROM op JOIN message ON message.id = op.messageId
                WHERE message.accountId = ? AND message.mailbox = ? AND op.notBefore <= ? ORDER BY op.id
                """, arguments: [account, mailbox, Date.now]).map {
                PendingOp(id: $0["id"], uid: $0["uid"], kind: OpKind(rawValue: $0["kind"])!, value: $0["value"])
            }
        }
    }

    /// The server took the op (or refused it for good). `removeMessage` when it left this mailbox.
    public func finish(_ op: PendingOp, removeMessage: Bool) throws {
        try db.write { db in
            if removeMessage {
                try db.execute(sql: "DELETE FROM message WHERE id = (SELECT messageId FROM op WHERE id = ?)", arguments: [op.id])
            }
            try db.execute(sql: "DELETE FROM op WHERE id = ?", arguments: [op.id])
        }
    }

    public func nextOpDue() throws -> Date? {
        try db.read { try Date.fetchOne($0, sql: "SELECT MIN(notBefore) FROM op") }
    }

    // MARK: piles

    public func pile(_ message: Int64) throws -> Pile {
        try db.read { try Pile.fetchOne($0, key: message) } ?? Pile(messageId: message)
    }

    /// Changes a message's piles; an empty pile row is removed.
    public func setPile(_ message: Int64, _ change: (inout Pile) -> Void) throws {
        try db.write { db in
            var p = try Pile.fetchOne(db, key: message) ?? Pile(messageId: message)
            change(&p)
            if p.isEmpty { _ = try Pile.deleteOne(db, key: message) } else { try p.save(db) }
        }
    }

    public func nextSnoozeEnd() throws -> Date? {
        try db.read { try Date.fetchOne($0, sql: "SELECT MIN(snoozedUntil) FROM pile WHERE snoozedUntil > ?", arguments: [Date.now]) }
    }

    // MARK: search and contacts

    static func index(_ id: Int64, _ p: MIME.Parsed, account: String, date: Date, _ db: Database) throws {
        let people = ([p.from] + p.recipients).map { "\($0.name) \($0.address)" }.joined(separator: " ")
        let body = String((p.text ?? p.html.map(MIME.stripTags) ?? "").prefix(100_000))
        try db.execute(sql: "INSERT OR REPLACE INTO message_fts (rowid, subject, people, body) VALUES (?, ?, ?, ?)", arguments: [id, p.subject, people, body])
        try noteContacts(p, account: account, date: date, db)
    }

    /// Mail you sent counts its recipients as people you write to; received mail counts the sender,
    /// unless it came from a list or a no-reply address.
    static func noteContacts(_ p: MIME.Parsed, account: String, date: Date, _ db: Database) throws {
        let sentByMe = p.from.address.lowercased() == account.lowercased()
        let people = sentByMe ? p.recipients : (p.listId == nil && !isNoReply(p.from.address) ? [p.from] : [])
        // Your own addresses are never contacts, whichever account the mail came through.
        let mine = Set(try String.fetchAll(db, sql: "SELECT lower(email) FROM account")).union([account.lowercased()])
        for a in people where !mine.contains(a.address.lowercased()) {
            try db.execute(sql: """
                INSERT INTO contact (address, name, lastSeen, sent, received) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(address) DO UPDATE SET
                    name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END,
                    lastSeen = MAX(lastSeen, excluded.lastSeen),
                    sent = sent + excluded.sent, received = received + excluded.received
                """, arguments: [a.address, a.name, date, sentByMe ? 1 : 0, sentByMe ? 0 : 1])
            // Writing to someone lets them past the Screener.
            if sentByMe { try db.execute(sql: "INSERT OR IGNORE INTO screener (address, decision) VALUES (?, 'allow')", arguments: [a.address]) }
        }
    }

    public func noteSent(_ raw: Data, account: String) throws {
        let p = MIME.parse(raw)
        try db.write { try Self.noteContacts(p, account: account, date: .now, $0) }
    }

    static func isNoReply(_ address: String) -> Bool {
        let local = address.split(separator: "@").first?.lowercased() ?? ""
        return local.contains(/^(no-?reply|do-?not-?reply|mailer-daemon|bounces?|notifications?)/)
    }

    /// People you write to first, then the most recent.
    public func contacts(matching prefix: String, limit: Int = 6) throws -> [Contact] {
        let p = prefix.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return [] }
        return try db.read { db in
            try Contact.fetchAll(db, sql: """
                SELECT * FROM contact
                WHERE address LIKE ?1 || '%' OR name LIKE ?1 || '%' OR name LIKE '% ' || ?1 || '%'
                ORDER BY sent > 0 DESC, lastSeen DESC LIMIT ?2
                """, arguments: [p, limit])
        }
    }

    /// Search-bar text → an FTS5 query: every word must match, each as a prefix.
    public static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacing("\"", with: "\"\"") + "\"*" }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    // MARK: drafts and outbox

    public func save(_ draft: Draft) throws -> Draft {
        try db.write { db in
            var d = draft
            d.updatedAt = .now
            try d.save(db)
            return d
        }
    }

    public func draft(_ id: Int64) throws -> Draft? {
        try db.read { try Draft.fetchOne($0, key: id) }
    }

    public func deleteDraft(_ id: Int64) throws {
        _ = try db.write { try Draft.deleteOne($0, key: id) }
    }

    public func enqueue(draft: Int64, account: Int64, raw: Data, recipients: [String], sendAt: Date) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE draftId = ?", arguments: [draft])
            try db.execute(sql: "INSERT INTO outbox (draftId, accountId, raw, recipients, sendAt) VALUES (?, ?, ?, ?, ?)",
                           arguments: [draft, account, raw, recipients.joined(separator: "\n"), sendAt])
        }
    }

    /// Undo send, or edit a message that failed: back to a plain draft.
    public func unqueue(draft: Int64) throws {
        try db.write { try $0.execute(sql: "DELETE FROM outbox WHERE draftId = ?", arguments: [draft]) }
    }

    public func dueOutbox() throws -> [OutboxItem] {
        try db.read { try OutboxItem.fetchAll($0, sql: "SELECT * FROM outbox WHERE sendAt <= ? ORDER BY sendAt", arguments: [Date.now]) }
    }

    public func nextOutboxDue() throws -> Date? {
        try db.read { try Date.fetchOne($0, sql: "SELECT MIN(sendAt) FROM outbox") }
    }

    /// Sent: the draft goes, and its outbox row with it.
    public func sent(_ item: OutboxItem) throws {
        try deleteDraft(item.draftId)
    }

    public func failed(_ item: OutboxItem, error: String, retryAt: Date) throws {
        try db.write {
            try $0.execute(sql: "UPDATE outbox SET attempts = attempts + 1, error = ?, sendAt = ? WHERE id = ?", arguments: [error, retryAt, item.id])
        }
    }

    // MARK: blobs

    static func blobURL(_ root: URL, _ hash: String) -> URL {
        let h = Array(hash)
        return root.appending(path: "\(String(h[0..<2]))/\(String(h[2..<4]))/\(hash).eml")
    }

    /// Written once, never edited: the same message in two folders is stored once.
    func writeBlob(_ raw: Data) throws -> String {
        let hash = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let url = Self.blobURL(blobs, hash)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try raw.write(to: url, options: [.atomic, .completeFileProtection])
        }
        return hash
    }

    public func raw(_ message: Message) throws -> Data {
        try Data(contentsOf: Self.blobURL(blobs, message.blob))
    }
}
