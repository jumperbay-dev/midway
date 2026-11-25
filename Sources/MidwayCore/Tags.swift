import Foundation
import GRDB

/// A local tag. Never written to the server; links are keyed by Message-ID, so they survive moves and UIDVALIDITY resets.
public struct Tag: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var name: String
    /// Index into the eight theme tag colours.
    public var colour: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A saved search that tags what it finds. Rules without a tag (the removed Screener's "let through") are ignored.
public struct TagRule: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tag_rule"
    public var id: Int64?
    public var tagId: Int64?
    public var query: String
    public var enabled = true

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Who sent a message and which of your addresses it reached, resolved once at ingest.
public enum Provenance {
    /// The receiving server's X-Original-To / X-Delivered-To / Delivered-To when it names an address other than
    /// the account's, else a To or Cc that is a plus-address of the account, else the account address.
    static func via(_ p: MIME.Parsed, account: String) -> String {
        let acct = account.lowercased()
        if let d = p.deliveredTo?.lowercased(), d.contains("@"), d != acct { return d }
        let (local, domain) = split(acct)
        let plus = p.recipients.map { $0.address.lowercased() }.first { r in
            let (l, d) = split(r)
            return d == domain && l.hasPrefix(local + "+")
        }
        return plus ?? acct
    }

    /// The chip text: "shop+" for me+shop@…, "bank@" for another address; nil for the account's own address.
    public static func label(via: String?, account: String) -> String? {
        guard let via, via != account.lowercased() else { return nil }
        let local = split(via).0
        if let plus = local.firstIndex(of: "+") { return local[local.index(after: plus)...] + "+" }
        return local + "@"
    }

    /// `Fieldnotes <weekly.fieldnotes.example>` → `weekly.fieldnotes.example`
    static func listId(_ header: String?) -> String? {
        guard let header else { return nil }
        return (header.firstMatch(of: /<([^>]+)>/).map { String($0.output.1) } ?? header).trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func split(_ address: String) -> (String, String) {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }
}

extension Store {
    // MARK: ingest

    /// Applies enabled rules (one tag's, or all) to some messages (or all). Returns how many links it added.
    @discardableResult
    static func runRules(only ids: [Int64]?, tag: Int64?, _ db: Database) throws -> Int {
        try run(try TagRule.fetchAll(db, sql: "SELECT * FROM tag_rule WHERE enabled ORDER BY id").filter { tag == nil || $0.tagId == tag }, only: ids, db)
    }

    @discardableResult
    static func run(_ rules: [TagRule], only ids: [Int64]?, _ db: Database) throws -> Int {
        let scope = ids.map { " AND message.id IN (\($0.map(String.init).joined(separator: ",")))" } ?? ""
        var added = 0
        for r in rules {
            guard let t = r.tagId, let q = try? Query(r.query) else { continue }
            try db.execute(sql: """
                INSERT OR IGNORE INTO tag_link (key, tagId, source, createdAt)
                SELECT DISTINCT message.key, ?, ?, ? FROM message WHERE message.key IS NOT NULL AND (\(q.sql))\(scope)
                """, arguments: [t, "rule:\(r.id ?? 0)", Date.now] + q.arguments)
            added += db.changesCount
        }
        return added
    }

    // MARK: tags

    public func createTag(_ name: String) throws -> Tag {
        try db.write { db in
            if let t = try Tag.fetchOne(db, sql: "SELECT * FROM tag WHERE name = ?", arguments: [name]) { return t }
            var t = Tag(name: name, colour: (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag") ?? 0) % 8)
            try t.insert(db)
            return t
        }
    }

    public func save(_ tag: Tag) throws {
        try db.write { try tag.update($0) }
    }

    public func deleteTag(_ id: Int64) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM tag_link WHERE tagId = ?", arguments: [id])
            _ = try Tag.deleteOne(db, key: id)
        }
    }

    /// Tags or untags a message by hand.
    public func setTag(_ tag: Int64, on key: String, _ on: Bool) throws {
        try db.write { db in
            if on {
                try db.execute(sql: "INSERT OR IGNORE INTO tag_link (key, tagId, source, createdAt) VALUES (?, ?, 'manual', ?)", arguments: [key, tag, Date.now])
            } else {
                try db.execute(sql: "DELETE FROM tag_link WHERE key = ? AND tagId = ?", arguments: [key, tag])
            }
        }
    }

    // MARK: rules

    /// Checks the query first; a rule that cannot parse is never stored. A rule without a tag lets
    /// matching senders through at once; a tag rule waits for new mail or a re-run.
    @discardableResult
    public func addRule(_ query: String, tag: Int64) throws -> TagRule {
        _ = try Query(query)
        return try db.write { db in
            var r = TagRule(tagId: tag, query: query)
            try r.insert(db)
            return r
        }
    }

    public func setRule(_ id: Int64, enabled: Bool) throws {
        try db.write { try $0.execute(sql: "UPDATE tag_rule SET enabled = ? WHERE id = ?", arguments: [enabled, id]) }
    }

    public func deleteRule(_ id: Int64) throws {
        try db.write { _ = try TagRule.deleteOne($0, key: id) }
    }

    /// How many stored messages a query matches.
    public func count(_ query: Query) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message WHERE \(query.sql)", arguments: query.arguments) ?? 0 }
    }

    /// Messages a tag's enabled rules match that do not have the tag yet.
    public func pendingRerun(tag: Int64) throws -> Int {
        try db.read { db in
            let qs = try TagRule.fetchAll(db, sql: "SELECT * FROM tag_rule WHERE enabled AND tagId = ?", arguments: [tag]).compactMap { try? Query($0.query) }
            guard !qs.isEmpty else { return 0 }
            let args = qs.reduce(StatementArguments([tag])) { $0 + $1.arguments }
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT message.key) FROM message
                WHERE message.key NOT IN (SELECT key FROM tag_link WHERE tagId = ?) AND (\(qs.map { "(\($0.sql))" }.joined(separator: " OR ")))
                """, arguments: args) ?? 0
        }
    }

    /// Runs a tag's rules over all stored mail. Manual tags are never removed.
    @discardableResult
    public func rerun(tag: Int64) throws -> Int {
        try db.write { try Self.runRules(only: nil, tag: tag, $0) }
    }

    // MARK: export

    struct Export: Codable {
        struct T: Codable { var name: String; var colour: Int }
        struct R: Codable { var tag: String?; var query: String; var enabled: Bool }
        struct L: Codable { var key: String; var tag: String; var source: String; var createdAt: Date }
        var version = 1
        var tags: [T]
        var rules: [R]
        var links: [L]
    }

    /// Tags, rules and links by Message-ID, as JSON for Time Machine-less moves to a new Mac.
    public func exportTags() throws -> Data {
        try db.read { db in
            let names = Dictionary(uniqueKeysWithValues: try Tag.fetchAll(db).map { ($0.id!, $0.name) })
            let e = Export(
                tags: try Tag.fetchAll(db).map { .init(name: $0.name, colour: $0.colour) },
                rules: try TagRule.fetchAll(db).compactMap { r in r.tagId.flatMap { names[$0] }.map { .init(tag: $0, query: r.query, enabled: r.enabled) } },
                links: try Row.fetchAll(db, sql: "SELECT key, tagId, source, createdAt FROM tag_link").compactMap { r in
                    names[r["tagId"]].map { Export.L(key: r["key"], tag: $0, source: r["source"], createdAt: r["createdAt"]) }
                })
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            return try enc.encode(e)
        }
    }

    /// Merges an export: nothing already here is changed or removed.
    public func importTags(_ data: Data) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let e = try dec.decode(Export.self, from: data)
        try db.write { db in
            for t in e.tags {
                try db.execute(sql: "INSERT OR IGNORE INTO tag (name, colour) VALUES (?, ?)", arguments: [t.name, min(max(t.colour, 0), 7)])
            }
            let ids = Dictionary(try Row.fetchAll(db, sql: "SELECT name, id FROM tag").map { (($0["name"] as String).lowercased(), $0["id"] as Int64) }, uniquingKeysWith: { a, _ in a })
            for r in e.rules where (try? Query(r.query)) != nil {
                guard let tag = r.tag.flatMap({ ids[$0.lowercased()] }) else { continue }
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM tag_rule WHERE tagId IS ? AND query = ?)", arguments: [tag, r.query]) ?? false
                if !exists { try db.execute(sql: "INSERT INTO tag_rule (tagId, query, enabled) VALUES (?, ?, ?)", arguments: [tag, r.query, r.enabled]) }
            }
            for l in e.links {
                guard let tag = ids[l.tag.lowercased()] else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO tag_link (key, tagId, source, createdAt) VALUES (?, ?, ?, ?)", arguments: [l.key, tag, l.source, l.createdAt])
            }
        }
    }
}
