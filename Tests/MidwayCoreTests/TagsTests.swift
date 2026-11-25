import Foundation
import GRDB
import Testing
@testable import MidwayCore

/// Three senders: a shop mail to a plus-address, a newsletter to a catch-all alias, and a friend.
func tagStore() throws -> (Store, Int64, URL) {
    let (store, a, dir) = try tempStore()
    try store.insert(raw: eml("Nordic Rail <booking@mail.nordicrail.example>", "me+shop@fastmail.com", "Your booking to Bergen", "Train 63",
                              extra: "Message-ID: <rail@x>\r\n"), uid: 1, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("Tidewater <hello@tidewater.example>", "undisclosed-recipients:;", "Issue 48", "Tide tables",
                              extra: "Message-ID: <tide@x>\r\nList-Id: Tidewater Review <weekly.tidewater.example>\r\nX-Original-To: news@icepuma.dev\r\n"),
                     uid: 2, state: .init(seen: true, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    try store.insert(raw: eml("Ada Lind <ada@example.com>", "me@fastmail.com", "Dinner on Friday?", "Cardamom",
                              extra: "Message-ID: <ada@x>\r\n"), uid: 3, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    return (store, a, dir)
}

func subjects(_ store: Store, _ q: String) throws -> Set<String> {
    let query = try Query(q)
    return Set(try store.db.read { try String.fetchAll($0, sql: "SELECT subject FROM message WHERE \(query.sql)", arguments: query.arguments) })
}

@Test func querySyntax() throws {
    let (store, _, dir) = try tagStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let rail = "Your booking to Bergen", tide = "Issue 48", ada = "Dinner on Friday?"
    #expect(try subjects(store, "domain:nordicrail.example") == [rail])  // subdomains count
    #expect(try subjects(store, "via:shop+") == [rail])
    #expect(try subjects(store, "to:news@") == [tide])
    #expect(try subjects(store, "list:tidewater") == [tide])
    #expect(try subjects(store, "from:\"Ada Lind\"") == [ada])
    #expect(try subjects(store, "from:ada OR subject:booking") == [ada, rail])
    #expect(try subjects(store, "-from:ada is:unread") == [rail])
    #expect(try subjects(store, "NOT (from:ada OR via:shop+)") == [tide])
    #expect(try subjects(store, "cardam") == [ada])  // words go to the full-text index, as prefixes
    #expect(try subjects(store, "older:100000d").isEmpty)  // the fixture mail is from a fixed date, so only a huge window stays empty
    #expect(try subjects(store, "http://example.com").isEmpty)  // not a term, just words
    for bad in ["from:", "(from:ada", "from:ada)", "is:weird", "older:soon", "NOT", ""] {
        #expect(throws: Query.Invalid.self) { try Query(bad) }
    }
}

@Test func provenance() throws {
    let (store, _, dir) = try tagStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let via = Dictionary(uniqueKeysWithValues: try store.db.read { try Row.fetchAll($0, sql: "SELECT subject, via, listId FROM message") }
        .map { ($0["subject"] as String, ($0["via"] as String, $0["listId"] as String?)) })
    #expect(via["Your booking to Bergen"]?.0 == "me+shop@fastmail.com")
    #expect(via["Issue 48"]! == ("news@icepuma.dev", "weekly.tidewater.example"))
    #expect(via["Dinner on Friday?"]?.0 == "me@fastmail.com")
    #expect(Provenance.label(via: "me+shop@fastmail.com", account: "Me@Fastmail.com") == "shop+")
    #expect(Provenance.label(via: "news@icepuma.dev", account: "me@fastmail.com") == "news@")
    #expect(Provenance.label(via: "me@fastmail.com", account: "me@fastmail.com") == nil)
}

@Test func rulesAndExport() throws {
    let (store, a, dir) = try tagStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    let travel = try store.createTag("Travel")
    #expect(try store.createTag("travel").id == travel.id)  // names are unique, any case
    #expect(throws: Query.Invalid.self) { try store.addRule("from:", tag: travel.id!) }

    // A rule tags new mail at once, and old mail when re-run. Manual tags stay.
    try store.setTag(travel.id!, on: "ada@x", true)
    try store.addRule("via:shop+", tag: travel.id!)
    #expect(try store.pendingRerun(tag: travel.id!) == 1)
    #expect(try store.rerun(tag: travel.id!) == 1)
    #expect(try subjects(store, "tag:travel") == ["Your booking to Bergen", "Dinner on Friday?"])
    try store.insert(raw: eml("Fjord Hotels <stay@fjord.example>", "me+shop@fastmail.com", "Your stay", "x", extra: "Message-ID: <hotel@x>\r\n"),
                     uid: 6, state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    #expect(try subjects(store, "tag:Travel").contains("Your stay"))
    #expect(try store.pendingRerun(tag: travel.id!) == 0)

    // Export, then import into a fresh store: same tags, rules and links.
    let data = try store.exportTags()
    let (other, _, otherDir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: otherDir) }
    try other.importTags(data)
    try other.importTags(data)  // twice changes nothing
    let (tags, rules, links) = try other.db.read { db in
        (try Tag.fetchAll(db).map(\.name), try TagRule.fetchCount(db), try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag_link"))
    }
    #expect(tags == ["Travel"])
    #expect(rules == 1)
    #expect(links == 3)
}
