import Foundation
import GRDB

/// Something worth having at hand from a message: a one-time code, a parcel, a key link or a booking reference.
public struct QuickItem: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "quick_item"

    public enum Kind: String, Codable, Sendable { case code, parcel, link, booking }

    public var messageId: Int64
    public var kind: Kind
    /// The code, tracking number or booking reference; for a link (or a parcel known only by its link), the URL.
    public var value: String
    /// "DHL", "Unsubscribe", "Booking"…
    public var label: String
    /// Where "Open tracking" or a link button goes. http(s) only.
    public var url: String?
    public var date: Date
    public var delivered = false

    /// The domain a link really goes to, shown on its button.
    public var host: String? { url.flatMap { URL(string: $0)?.host() }.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } }
}

/// The local extractor: patterns only, no AI and no network. Runs on every new message.
// ponytail: English and German wording, the carriers in the spec; add patterns as real mail misses them
public enum Quick {
    /// One-time codes are shown for this long after the message arrives.
    public static let codeLifetime: TimeInterval = 15 * 60
    /// Deliveries drop off the list after this long, or when a "delivered" mail arrives.
    public static let deliveryLifetime: TimeInterval = 30 * 86400

    public static func extract(_ p: MIME.Parsed, message: Int64, date: Date) -> [QuickItem] {
        let body = String((p.text ?? p.html.map(MIME.stripTags) ?? "").prefix(20_000))
        let text = p.subject + "\n" + body
        let links = anchors(p)
        func item(_ kind: QuickItem.Kind, _ value: String, _ label: String, _ url: String? = nil, delivered: Bool = false) -> QuickItem {
            QuickItem(messageId: message, kind: kind, value: value, label: label, url: url, date: date, delivered: delivered)
        }
        var out: [QuickItem] = []
        let parcels = self.parcels(text, links: links)
        let delivered = isDelivered(text)
        out += parcels.map { item(.parcel, $0.value, $0.label, $0.url, delivered: delivered) }
        let taken = Set(parcels.map(\.value))
        if let c = code(text), !taken.contains(c) { out.append(item(.code, c, "Code")) }
        if let b = booking(text), !taken.contains(b.value) { out.append(item(.booking, b.value, b.label)) }
        out += keyLinks(links, listUnsubscribe: p.listUnsubscribe).map { item(.link, $0.url, $0.label, $0.url) }
        return out
    }

    // MARK: links

    struct Link { var url: String; var text: String }

    /// `<a href>` with its text from HTML, and in plain text each URL with the words before it on its line.
    static func anchors(_ p: MIME.Parsed) -> [Link] {
        var out: [Link] = []
        if let html = p.html {
            for m in html.matches(of: /(?is)<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/) {
                out.append(Link(url: m.output.1.replacing("&amp;", with: "&").trimmingCharacters(in: .whitespaces),
                                text: MIME.stripTags(String(m.output.2)).split(whereSeparator: \.isWhitespace).joined(separator: " ")))
            }
        }
        for line in (p.text ?? "").split(whereSeparator: \.isNewline) {
            for m in line.matches(of: /https?:\/\/[^\s<>"')\]]+/) {
                out.append(Link(url: String(m.output), text: String(line[..<m.range.lowerBound])))
            }
        }
        return out.filter { ["http", "https"].contains(URL(string: $0.url)?.scheme?.lowercased() ?? "") }
    }

    static func keyLinks(_ links: [Link], listUnsubscribe: String?) -> [(label: String, url: String)] {
        let meeting = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
        let rules: [(String, (Link) -> Bool)] = [
            ("Join meeting", { l in
                let host = URL(string: l.url)?.host()?.lowercased() ?? ""
                return meeting.contains { host == $0 || host.hasSuffix("." + $0) } || l.text.contains(/(?i)join (the )?(meeting|call)|an (der )?besprechung teilnehmen/)
            }),
            ("Reset password", { $0.text.contains(/(?i)reset (your )?password|(new|neues) pass(word|wort)|passwort zurücksetzen/) }),
            ("Verify", { $0.text.contains(/(?i)verify|verification|activate|confirm your (e-?mail|account|address)|(e-?mail|konto|adresse) bestätigen/) }),
            ("Confirm", { $0.text.contains(/(?i)\bconfirm\b|\bbestätigen\b/) }),
            ("Unsubscribe", { $0.text.contains(/(?i)unsubscribe|abmelden|abbestellen/) }),
        ]
        var out: [(String, String)] = []
        for (label, matches) in rules {
            if let l = links.first(where: matches) { out.append((label, l.url)) }
        }
        // List-Unsubscribe: <https://…>, <mailto:…>; only the web one is a button.
        if !out.contains(where: { $0.0 == "Unsubscribe" }), let header = listUnsubscribe,
           let url = header.matches(of: /<(https?:[^>]+)>/).first.map({ String($0.output.1) }) {
            out.append(("Unsubscribe", url))
        }
        return out
    }

    // MARK: codes

    /// A 4–8 digit (or capitals-and-digits) code close to a word like "code" or "verification".
    static func code(_ text: String) -> String? {
        let words = /(?i)\b(code|codes|verification|verify|otp|passcode|pin|one[- ]time|security|login|sign[- ]in|bestätigungscode|sicherheitscode|einmalcode|anmeldecode|tan)\b/
        for m in text.matches(of: /\b(?=[A-Z0-9]*\d)[A-Z0-9]{4,8}\b/) {
            let c = String(m.output)
            if c.count == 4, c.wholeMatch(of: /(19|20)\d\d/) != nil { continue }  // a year
            if c.allSatisfy(\.isLetter) { continue }
            let before = text[(text.index(m.range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex)..<m.range.lowerBound]
            let after = text[m.range.upperBound..<(text.index(m.range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex)]
            if before.contains(words) || after.contains(words) { return c }
        }
        return nil
    }

    // MARK: parcels

    struct Carrier: Sendable {
        let name: String
        let pattern: String
        /// Plain digit runs only count when the carrier is named in the mail.
        let named: Bool
        let url: @Sendable (String) -> String?
    }

    static let carriers: [Carrier] = {
        let dhl: @Sendable (String) -> String? = { "https://www.dhl.com/global-en/home/tracking/tracking-parcel.html?submit=1&tracking-id=\($0)" }
        return [
            Carrier(name: "UPS", pattern: #"\b1Z[0-9A-Z]{16}\b"#, named: false) { "https://www.ups.com/track?tracknum=\($0)" },
            Carrier(name: "DHL", pattern: #"\bJJD\d{18}\b"#, named: false, url: dhl),
            Carrier(name: "Post", pattern: #"\b[A-Z]{2}\d{9}[A-Z]{2}\b"#, named: false) { n in
                switch n.suffix(2) {
                case "DE": dhl(n)
                case "GB": "https://www.royalmail.com/track-your-item#/tracking-results/\(n)"
                case "AT": "https://www.post.at/s/sendungsdetails?snr=\(n)"
                default: nil
                }
            },
            Carrier(name: "DHL", pattern: #"\b(?:00340\d{15}|\d{12}|\d{20})\b"#, named: true, url: dhl),
            Carrier(name: "DPD", pattern: #"\b\d{14}\b"#, named: true) { "https://tracking.dpd.de/status/de_DE/parcel/\($0)" },
            Carrier(name: "GLS", pattern: #"\b\d{11,12}\b"#, named: true) { "https://gls-group.com/DE/de/paketverfolgung?match=\($0)" },
            Carrier(name: "Hermes", pattern: #"\b(?:H\d{19}|\d{14}|\d{16})\b"#, named: true) { "https://www.myhermes.de/empfangen/sendungsverfolgung/sendungsinformation#\($0)" },
            Carrier(name: "FedEx", pattern: #"\b(?:\d{12}|\d{15})\b"#, named: true) { "https://www.fedex.com/fedextrack/?trknbr=\($0)" },
        ]
    }()

    static var shippingWords: Regex<Substring> { /(?i)track|sendung|paket|parcel|package|shipment|shipped|versand|zustell|deliver|lieferung/ }

    /// Tracking numbers by carrier pattern, and "track your parcel" links. Only in mail that talks about shipping.
    static func parcels(_ text: String, links: [Link]) -> [(value: String, label: String, url: String?)] {
        guard text.contains(shippingWords) else { return [] }
        let trackLink = links.first { $0.text.contains(/(?i)track|verfolg|where is my|wo ist mein/) }
        var out: [(String, String, String?)] = []
        for c in carriers {
            if c.named, text.firstMatch(of: try! Regex("(?i)\\b\(c.name)\\b")) == nil { continue }
            for m in text.matches(of: try! Regex(c.pattern)) {
                let n = String(text[m.range])
                guard !out.contains(where: { $0.0 == n }) else { continue }
                out.append((n, c.name, c.url(n) ?? trackLink?.url))
            }
        }
        if out.isEmpty, let l = trackLink {
            let host = URL(string: l.url)?.host()?.lowercased() ?? ""
            let name = ["dhl": "DHL", "ups": "UPS", "dpd": "DPD", "gls": "GLS", "hermes": "Hermes", "fedex": "FedEx"].first { host.contains($0.key) }?.value
            out.append((l.url, name ?? "Parcel", l.url))
        }
        return out
    }

    static func isDelivered(_ text: String) -> Bool {
        text.contains(/(?i)\b(has been|was|been) delivered\b|\bdelivered today\b|\bwurde zugestellt\b|\bist zugestellt\b|\bzugestellt am\b/)
            && !text.contains(/(?i)out for delivery|will be delivered|wird (heute |morgen )?zugestellt|voraussichtlich/)
    }

    // MARK: bookings

    /// "Booking reference: KXPTQR", "Order #2291", "Buchungsnummer 4711-22".
    static func booking(_ text: String) -> (value: String, label: String)? {
        let pattern = /(?i)\b(booking|confirmation|reservation|order|buchungs|bestell|auftrags|reservierungs)[ -]?(number|no\.?|nr\.?|code|reference|ref\.?|nummer|id)?\s*[:#]?\s*#?\s*([A-Za-z0-9][A-Za-z0-9-]{3,15})\b/
        for m in text.matches(of: pattern) {
            let v = String(m.output.3)
            let caps = v.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "-" }
            guard caps, v.contains(where: \.isNumber) || (v.count == 6 && v.allSatisfy(\.isLetter)) else { continue }
            let word = m.output.1.lowercased()
            let label = word.hasPrefix("order") || word.hasPrefix("bestell") || word.hasPrefix("auftrag") ? "Order"
                : word.hasPrefix("confirm") ? "Confirmation" : word.hasPrefix("reserv") ? "Reservation" : "Booking"
            return (v, label)
        }
        return nil
    }
}

extension Store {
    /// Runs in the insert's transaction. A "delivered" mail also clears earlier mail about the same parcel.
    static func noteQuick(_ id: Int64, _ p: MIME.Parsed, date: Date, _ db: Database) throws {
        let items = Quick.extract(p, message: id, date: date)
        for i in items { try i.insert(db, onConflict: .ignore) }
        let done = items.filter { $0.kind == .parcel && $0.delivered }.map(\.value)
        if !done.isEmpty {
            try db.execute(sql: "UPDATE quick_item SET delivered = 1 WHERE kind = 'parcel' AND value IN (\(databaseQuestionMarks(count: done.count)))", arguments: StatementArguments(done))
        }
    }

    public func quickItems(_ message: Int64) throws -> [QuickItem] {
        try db.read { try QuickItem.fetchAll($0, sql: "SELECT * FROM quick_item WHERE messageId = ?", arguments: [message]) }
    }

    /// The newest one-time code still inside its 15 minutes, with who sent it.
    public func latestCode(now: Date = .now) throws -> (code: String, from: String)? {
        try db.read { db in
            try GRDB.Row.fetchOne(db, sql: """
                SELECT quick_item.value, CASE message.fromName WHEN '' THEN message.fromAddr ELSE message.fromName END AS sender
                FROM quick_item JOIN message ON message.id = quick_item.messageId
                WHERE quick_item.kind = 'code' AND quick_item.date > ? ORDER BY quick_item.date DESC LIMIT 1
                """, arguments: [now.addingTimeInterval(-Quick.codeLifetime)]).map { ($0[0], $0[1]) }
        }
    }

    /// Parcels on their way: not delivered, under 30 days old, newest mail per parcel.
    public func deliveries(now: Date = .now) throws -> [(item: QuickItem, subject: String)] {
        try db.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT quick_item.*, message.subject, MAX(quick_item.date) FROM quick_item JOIN message ON message.id = quick_item.messageId
                WHERE quick_item.kind = 'parcel' AND quick_item.delivered = 0 AND quick_item.date > ?
                GROUP BY quick_item.value ORDER BY quick_item.date DESC
                """, arguments: [now.addingTimeInterval(-Quick.deliveryLifetime)]).map { (try QuickItem(row: $0), $0["subject"]) }
        }
    }
}
