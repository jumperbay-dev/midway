import Foundation

/// Just enough RFC 5322 / 2045 / 2047 to list and show a message.
/// ponytail: no attachments, cid: images or S/MIME yet; swap for a MIME library if those land.
public enum MIME {
    public struct Address: Equatable, Sendable {
        public var name: String
        public var address: String

        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    public struct Parsed: Sendable {
        public var subject = ""
        public var from = Address(name: "", address: "")
        public var to = Address(name: "", address: "")
        /// Every To and Cc address.
        public var recipients: [Address] = []
        public var replyTo: Address?
        public var references: String?
        public var inReplyTo: String?
        /// Message-IDs this one answers, from In-Reply-To and References, without angle brackets.
        public var answers: [String] {
            ((inReplyTo ?? "") + " " + (references ?? "")).matches(of: /<([^>]+)>/).map { String($0.output.1) }
        }
        public var listId: String?
        public var date: Date?
        public var messageId: String?
        public var html: String?
        public var text: String?
        public var preview: String {
            let src = text ?? html.map(stripTags) ?? ""
            let flat = src.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return String(flat.prefix(160))
        }
    }

    public static func parse(_ raw: Data) -> Parsed {
        let (headers, body) = split(raw)
        var p = Parsed()
        p.subject = decodeWords(headers["subject"] ?? "")
        p.from = address(decodeWords(headers["from"] ?? ""))
        p.to = address(decodeWords(headers["to"] ?? ""))
        p.recipients = addresses(decodeWords(headers["to"] ?? "")) + addresses(decodeWords(headers["cc"] ?? ""))
        p.replyTo = headers["reply-to"].map { address(decodeWords($0)) }
        p.references = headers["references"]
        p.inReplyTo = headers["in-reply-to"]
        p.listId = headers["list-id"]
        p.date = headers["date"].flatMap(date)
        p.messageId = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        walk(headers: headers, body: body, into: &p)
        return p
    }

    // MARK: structure

    /// Headers keyed lowercase (first wins), unfolded.
    static func split(_ raw: Data) -> ([String: String], Data) {
        let bytes = [UInt8](raw)
        var end = bytes.count, bodyStart = bytes.count
        for i in 0..<bytes.count where bytes[i] == 0x0A {
            if i + 1 < bytes.count, bytes[i + 1] == 0x0A { end = i; bodyStart = i + 2; break }
            if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { end = i; bodyStart = i + 3; break }
        }
        let headerData = Data(bytes[0..<end])
        // RFC 6532 allows UTF-8 headers; fall back to Latin-1 which never fails.
        let text = String(data: headerData, encoding: .utf8) ?? String(decoding: headerData, as: Unicode.ASCII.self)
        var headers: [String: String] = [:]
        var current: (String, String)?
        func flush() {
            if let (k, v) = current, headers[k] == nil { headers[k] = v.trimmingCharacters(in: .whitespaces) }
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if line.first == " " || line.first == "\t", current != nil {
                current!.1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                flush()
                current = (line[..<colon].lowercased(), String(line[line.index(after: colon)...]))
            }
        }
        flush()
        return (headers, Data(bytes[min(bodyStart, bytes.count)...]))
    }

    /// `text/html; charset="utf-8"` → ("text/html", ["charset": "utf-8"])
    static func contentType(_ value: String?) -> (String, [String: String]) {
        guard let value else { return ("text/plain", [:]) }
        var parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.isEmpty ? "text/plain" : parts.removeFirst().lowercased()
        var params: [String: String] = [:]
        for p in parts {
            guard let eq = p.firstIndex(of: "=") else { continue }
            params[p[..<eq].trimmingCharacters(in: .whitespaces).lowercased()] =
                p[p.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return (type, params)
    }

    static func walk(headers: [String: String], body: Data, into p: inout Parsed, depth: Int = 0) {
        guard depth < 8 else { return }
        let (type, params) = contentType(headers["content-type"])
        if headers["content-disposition"]?.lowercased().hasPrefix("attachment") == true { return }
        if type.hasPrefix("multipart/"), let boundary = params["boundary"] {
            for part in parts(body, boundary: boundary) {
                let (h, b) = split(part)
                walk(headers: h, body: b, into: &p, depth: depth + 1)
            }
            return
        }
        guard type == "text/plain" || type == "text/html" else { return }
        let decoded = transferDecode(body, encoding: headers["content-transfer-encoding"])
        let s = string(decoded, charset: params["charset"])
        if type == "text/html", p.html == nil { p.html = s }
        if type == "text/plain", p.text == nil { p.text = s }
    }

    static func parts(_ body: Data, boundary: String) -> [Data] {
        let delim = Data("--\(boundary)".utf8)
        var out: [Data] = []
        var cursor = body.startIndex
        var start: Data.Index?
        while let r = body.range(of: delim, in: cursor..<body.endIndex) {
            if let s = start {
                // The line break before a boundary belongs to the delimiter (RFC 2046 5.1.1).
                var e = r.lowerBound
                if e > s, body[e - 1] == 0x0A { e -= 1 }
                if e > s, body[e - 1] == 0x0D { e -= 1 }
                out.append(body[s..<e])
            }
            var next = r.upperBound
            if body[next...].starts(with: Data("--".utf8)) { break }
            while next < body.endIndex, body[next] != 0x0A { next += 1 }
            start = min(next + 1, body.endIndex)
            cursor = start!
        }
        return out
    }

    // MARK: decoding

    static func transferDecode(_ data: Data, encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable": quotedPrintable(data, underscoreIsSpace: false)
        default: data
        }
    }

    static func quotedPrintable(_ data: Data, underscoreIsSpace: Bool) -> Data {
        let b = [UInt8](data)
        var out = Data(capacity: b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x41...0x46: c - 0x37
            case 0x61...0x66: c - 0x57
            default: nil
            }
        }
        while i < b.count {
            if b[i] == 0x3D {  // =
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
                if i + 1 < b.count, b[i + 1] == 0x0A { i += 2; continue }  // soft break
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { i += 3; continue }
            }
            out.append(underscoreIsSpace && b[i] == 0x5F ? 0x20 : b[i])
            i += 1
        }
        return out
    }

    static func string(_ data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                return s
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// RFC 2047: `=?utf-8?Q?Gr=C3=BC=C3=9Fe?=`; whitespace between adjacent encoded words is dropped.
    public static func decodeWords(_ s: String) -> String {
        let pattern = /=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/
        var out = ""
        var rest = Substring(s)
        var lastWasWord = false
        while let m = rest.firstMatch(of: pattern) {
            let gap = rest[rest.startIndex..<m.range.lowerBound]
            if !(lastWasWord && gap.allSatisfy(\.isWhitespace)) { out += gap }
            let payload = Data(m.output.3.utf8)
            let bytes = m.output.2.lowercased() == "b"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? payload
                : quotedPrintable(payload, underscoreIsSpace: true)
            out += string(bytes, charset: String(m.output.1))
            rest = rest[m.range.upperBound...]
            lastWasWord = true
        }
        return out + rest
    }

    /// First address of `"Name" <a@b>`, `Name <a@b>` or `a@b`.
    public static func address(_ s: String) -> Address {
        if let lt = s.firstIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return Address(name: name, address: String(s[s.index(after: lt)..<gt]))
        }
        let a = s.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return Address(name: "", address: a)
    }

    /// `"Lind, Ada" <ada@x>, bob@y` → both, splitting only on commas outside quotes and angle brackets.
    public static func addresses(_ s: String) -> [Address] {
        var out: [String] = [], cur = "", quoted = false, angled = false
        for c in s {
            switch c {
            case "\"": quoted.toggle()
            case "<" where !quoted: angled = true
            case ">" where !quoted: angled = false
            case "," where !quoted && !angled: out.append(cur); cur = ""; continue
            default: break
            }
            cur.append(c)
        }
        out.append(cur)
        return out.map(address).filter { $0.address.contains("@") }
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        // Drop the comment some senders append: "... +0100 (CET)"
        let clean = s.replacing(/\s*\(.*\)\s*$/, with: "")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = format
            if let d = f.date(from: clean) { return d }
        }
        return nil
    }

    public static func stripTags(_ html: String) -> String {
        html.replacing(/(?is)<(style|script|head)[^>]*>.*?<\/\1>/, with: " ")
            .replacing(/<[^>]+>/, with: " ")
            .replacing("&nbsp;", with: " ").replacing("&amp;", with: "&")
    }
}
