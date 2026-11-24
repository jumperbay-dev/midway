import Foundation
import GRDB

/// The search-bar syntax, shared by search, tag rules and the Screener: words and `key:value` terms,
/// joined by AND (or nothing), OR, NOT or a leading `-`, with brackets. Compiles to an SQL condition on `message`.
///
/// Terms: from:, domain:, to: or via:, account:, list:, subject:, tag:, is:unread|read|starred|known,
/// older:30d, newer:2w (d, w, m, y). Anything else is a word for the full-text index.
// ponytail: no has:attachment, header: or is:reply-to-me yet; they need columns the store does not keep
public struct Query {
    public let sql: String
    public let arguments: StatementArguments

    public struct Invalid: LocalizedError {
        public let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    public init(_ text: String, now: Date = .now, calendar: Calendar = .current) throws {
        var p = Parser(tokens: Self.tokens(text), now: now, calendar: calendar)
        guard !p.tokens.isEmpty else { throw Invalid("Type something to match") }
        let (sql, args) = try p.or()
        guard p.i == p.tokens.count else { throw Invalid("Unexpected “)”") }
        self.sql = sql
        arguments = StatementArguments(args)
    }

    enum Token: Equatable {
        case open, close, word(String)
    }

    /// Splits on spaces and brackets; double quotes keep spaces (`from:"Ada Lind"`).
    static func tokens(_ text: String) -> [Token] {
        var out: [Token] = [], word = "", quoted = false
        func flush() { if !word.isEmpty { out.append(.word(word)); word = "" } }
        for c in text {
            if c == "\"" { quoted.toggle() }
            else if quoted { word.append(c) }
            else if c.isWhitespace { flush() }
            else if c == "(" || c == ")" { flush(); out.append(c == "(" ? .open : .close) }
            else { word.append(c) }
        }
        flush()
        return out
    }

    typealias Part = (String, [(any DatabaseValueConvertible)?])

    struct Parser {
        let tokens: [Token]
        let now: Date
        let calendar: Calendar
        var i = 0

        init(tokens: [Token], now: Date, calendar: Calendar) {
            self.tokens = tokens
            self.now = now
            self.calendar = calendar
        }

        var peek: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func or() throws -> Part {
            var l = try and()
            while peek == .word("OR") {
                i += 1
                let r = try and()
                l = ("(\(l.0) OR \(r.0))", l.1 + r.1)
            }
            return l
        }

        mutating func and() throws -> Part {
            var l = try unary()
            while let t = peek, t != .close, t != .word("OR") {
                if t == .word("AND") { i += 1 }
                let r = try unary()
                l = ("(\(l.0) AND \(r.0))", l.1 + r.1)
            }
            return l
        }

        mutating func unary() throws -> Part {
            guard let t = peek else { throw Invalid("The query ends too early") }
            i += 1
            switch t {
            case .open:
                let e = try or()
                guard peek == .close else { throw Invalid("A “(” is never closed") }
                i += 1
                return e
            case .close:
                throw Invalid("Unexpected “)”")
            case .word("NOT"):
                let e = try unary()
                return ("NOT \(e.0)", e.1)
            case .word(let w) where w.hasPrefix("-") && w.count > 1:
                let e = try term(String(w.dropFirst()))
                return ("NOT \(e.0)", e.1)
            case .word(let w):
                return try term(w)
            }
        }

        static let keys: Set = ["from", "domain", "to", "via", "account", "list", "subject", "tag", "is", "older", "newer"]

        func term(_ w: String) throws -> Part {
            guard let colon = w.firstIndex(of: ":"), Self.keys.contains(w[..<colon].lowercased()) else {
                return ("message.id IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)", [Store.ftsQuery(w)])
            }
            let key = w[..<colon].lowercased(), v = String(w[w.index(after: colon)...])
            guard !v.isEmpty else { throw Invalid("\(key): needs a value") }
            let like = "%" + escape(v) + "%"
            switch key {
            case "from":
                return ("(message.fromAddr LIKE ? ESCAPE '\\' OR message.fromName LIKE ? ESCAPE '\\')", [like, like])
            case "domain":
                let d = escape(v.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@")))
                return ("(lower(message.fromAddr) LIKE ? ESCAPE '\\' OR lower(message.fromAddr) LIKE ? ESCAPE '\\')", ["%@" + d, "%." + d])
            case "to", "via":
                // shop+ is me+shop@…, bank@ is bank@… at any domain.
                let pattern = v.hasSuffix("+") ? "%+" + escape(String(v.dropLast())) + "@%" : v.hasSuffix("@") ? escape(v) + "%" : like
                return ("message.via LIKE ? ESCAPE '\\'", [pattern])
            case "account":
                return ("message.accountId IN (SELECT id FROM account WHERE email LIKE ? ESCAPE '\\')", [like])
            case "list":
                return ("message.listId LIKE ? ESCAPE '\\'", [like])
            case "subject":
                return ("message.subject LIKE ? ESCAPE '\\'", [like])
            case "tag":
                return ("message.key IN (SELECT tag_link.key FROM tag_link JOIN tag ON tag.id = tag_link.tagId WHERE tag.name = ?)", [v])
            case "is":
                switch v.lowercased() {
                case "unread": return ("message.seen = 0", [])
                case "read": return ("message.seen = 1", [])
                case "starred": return ("message.flagged = 1", [])
                case "known": return ("EXISTS (SELECT 1 FROM contact WHERE contact.address = message.fromAddr AND contact.sent > 0)", [])
                default: throw Invalid("is: takes unread, read, starred or known")
                }
            default:  // older, newer
                guard let m = v.wholeMatch(of: /(\d+)([dwmy])/), let n = Int(m.output.1) else { throw Invalid("\(key): takes an age like 30d, 2w, 6m or 1y") }
                let unit: Calendar.Component = ["d": .day, "w": .weekOfYear, "m": .month, "y": .year][String(m.output.2)]!
                let date = calendar.date(byAdding: unit, value: -n, to: now) ?? now
                return (key == "older" ? "message.date < ?" : "message.date >= ?", [date])
            }
        }

        func escape(_ s: String) -> String {
            s.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
        }
    }
}
