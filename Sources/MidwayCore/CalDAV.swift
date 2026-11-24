import Foundation

/// A parsed XML element, names without namespace prefixes.
struct XNode: Sendable {
    var name: String
    var text = ""
    var children: [XNode] = []
    var attrs: [String: String] = [:]

    func first(_ n: String) -> XNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [XNode] { children.filter { $0.name == n } }
    /// Depth-first search below this node.
    func find(_ n: String) -> XNode? {
        for c in children { if c.name == n { return c }; if let f = c.find(n) { return f } }
        return nil
    }

    static func parse(_ data: Data) -> XNode? {
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        let b = Builder()
        p.delegate = b
        return p.parse() ? b.root : nil
    }

    final class Builder: NSObject, XMLParserDelegate {
        var stack: [XNode] = []
        var root: XNode?
        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(XNode(name: name, attrs: attributes))
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if !stack.isEmpty { stack[stack.count - 1].text += s } }
        func parser(_ p: XMLParser, foundCDATA d: Data) { if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: d, as: UTF8.self) } }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            var n = stack.removeLast()
            n.text = n.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if stack.isEmpty { root = n } else { stack[stack.count - 1].children.append(n) }
        }
    }
}

/// Just enough CalDAV (RFC 4791): discovery, ETag listing, multiget, PUT and DELETE, over URLSession with
/// system trust. Redirects are followed by hand so PROPFIND stays PROPFIND.
public struct CalDAV: Sendable {
    public struct Remote: Sendable, Hashable {
        public var url: URL
        public var name: String
        public var colour: String?
        public var ctag: String?
        public var writable: Bool
        public init(url: URL, name: String, colour: String?, ctag: String?, writable: Bool) {
            self.url = url; self.name = name; self.colour = colour; self.ctag = ctag; self.writable = writable
        }
    }

    public struct Resource: Sendable, Hashable {
        public var href: String
        public var etag: String
        public var ics: String
        public init(href: String, etag: String, ics: String) { self.href = href; self.etag = etag; self.ics = ics }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case status(Int, String)
        /// 412 on PUT or DELETE: changed on the server since we fetched it.
        case conflict
        case unauthorized
        case malformed(String)
        public var description: String {
            switch self {
            case .status(let c, let u): "CalDAV \(c) at \(u)"
            case .conflict: "The event changed on the server."
            case .unauthorized: "The calendar server refused the sign-in."
            case .malformed(let s): "Unexpected calendar server reply: \(s)"
            }
        }
    }

    let session: URLSession
    let authorization: @Sendable () async throws -> String

    public init(login: @escaping @Sendable () async throws -> Login, session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        authorization = {
            switch try await login() {
            case .plain(let u, let p): "Basic " + Data("\(u):\(p)".utf8).base64EncodedString()
            case .xoauth2(_, let token): "Bearer \(token)"
            }
        }
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? { nil }
    }

    /// Where discovery starts: Fastmail and Google directly, anyone else through /.well-known/caldav.
    public static func start(for account: Account) -> URL {
        switch account.kind {
        case .google: URL(string: "https://apidata.googleusercontent.com/caldav/v2/\(account.email)/user")!
        case .password:
            account.imapHost.hasSuffix("fastmail.com") ? URL(string: "https://caldav.fastmail.com/dav/")!
                : URL(string: "https://\(account.email.split(separator: "@").last ?? "")/.well-known/caldav")!
        }
    }

    func send(_ method: String, _ url: URL, depth: String? = nil, body: String? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse, URL) {
        var url = url
        for _ in 0..<4 {
            var r = URLRequest(url: url, timeoutInterval: 30)
            r.httpMethod = method
            r.setValue(try await authorization(), forHTTPHeaderField: "Authorization")
            if let depth { r.setValue(depth, forHTTPHeaderField: "Depth") }
            if let body {
                r.httpBody = Data(body.utf8)
                r.setValue(body.hasPrefix("BEGIN:VCALENDAR") ? "text/calendar; charset=utf-8" : "application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            let (data, resp) = try await session.data(for: r)
            guard let h = resp as? HTTPURLResponse else { throw Failure.malformed("not HTTP") }
            if (300..<400).contains(h.statusCode), let loc = h.value(forHTTPHeaderField: "Location"), let next = URL(string: loc, relativeTo: url) {
                url = next.absoluteURL
                continue
            }
            if h.statusCode == 401 || h.statusCode == 403 { throw Failure.unauthorized }
            if h.statusCode == 412 { throw Failure.conflict }
            guard (200..<300).contains(h.statusCode) else { throw Failure.status(h.statusCode, url.absoluteString) }
            return (data, h, url)
        }
        throw Failure.malformed("too many redirects")
    }

    func multistatus(_ data: Data) throws -> [XNode] {
        guard let root = XNode.parse(data), root.name == "multistatus" else { throw Failure.malformed(String(decoding: data.prefix(200), as: UTF8.self)) }
        return root.all("response")
    }

    /// The props of each response's 200 propstat.
    static func props(_ r: XNode) -> XNode? {
        r.all("propstat").first { ($0.first("status")?.text ?? "").contains(" 200") }?.first("prop")
    }

    func href(_ n: XNode?, base: URL) -> URL? {
        (n?.first("href")?.text).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
    }

    /// .well-known or principal → current-user-principal → calendar-home-set → the calendars in it.
    public func discover(_ start: URL) async throws -> [Remote] {
        let ask = #"<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:current-user-principal/><c:calendar-home-set/></d:prop></d:propfind>"#
        let (d1, _, base1) = try await send("PROPFIND", start, depth: "0", body: ask)
        var p = try multistatus(d1).compactMap(Self.props).first
        var base = base1
        if p?.first("calendar-home-set")?.first("href") == nil, let principal = href(p?.first("current-user-principal"), base: base1) {
            let (d2, _, base2) = try await send("PROPFIND", principal, depth: "0", body: ask)
            p = try multistatus(d2).compactMap(Self.props).first
            base = base2
        }
        guard let home = href(p?.first("calendar-home-set"), base: base) else { throw Failure.malformed("no calendar-home-set") }
        let list = #"""
            <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:cs="http://calendarserver.org/ns/" xmlns:a="http://apple.com/ns/ical/">
            <d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><cs:getctag/><c:supported-calendar-component-set/><d:current-user-privilege-set/></d:prop></d:propfind>
            """#
        let (d3, _, base3) = try await send("PROPFIND", home, depth: "1", body: list)
        return try multistatus(d3).compactMap { r -> Remote? in
            guard let p = Self.props(r), p.first("resourcetype")?.first("calendar") != nil, let url = href(r, base: base3) else { return nil }
            // Calendars that can hold events; task lists and the scheduling inbox stay out.
            if let set = p.first("supported-calendar-component-set"), !set.all("comp").contains(where: { $0.attrs["name"] == "VEVENT" }) { return nil }
            let privileges = p.first("current-user-privilege-set")
            let writable = privileges == nil || privileges!.find("write") != nil || privileges!.find("write-content") != nil || privileges!.find("all") != nil
            let colour = p.first("calendar-color")?.text.prefix(7)
            return Remote(url: url, name: p.first("displayname")?.text.isEmpty == false ? p.first("displayname")!.text : url.lastPathComponent,
                          colour: colour.map(String.init), ctag: p.first("getctag")?.text, writable: writable)
        }
    }

    /// href → ETag for every event in the calendar.
    public func etags(_ calendar: URL) async throws -> [String: String] {
        let q = #"<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"/></c:comp-filter></c:filter></c:calendar-query>"#
        let (data, _, base) = try await send("REPORT", calendar, depth: "1", body: q)
        var out: [String: String] = [:]
        for r in try multistatus(data) {
            guard let u = href(r, base: base), let tag = Self.props(r)?.first("getetag")?.text else { continue }
            out[u.path(percentEncoded: true)] = tag
        }
        return out
    }

    /// The events at these hrefs (paths), 50 per request.
    public func multiget(_ calendar: URL, _ hrefs: [String]) async throws -> [Resource] {
        var out: [Resource] = []
        for chunk in stride(from: 0, to: hrefs.count, by: 50).map({ Array(hrefs[$0..<min($0 + 50, hrefs.count)]) }) {
            let list = chunk.map { "<d:href>\(xmlEscape($0))</d:href>" }.joined()
            let q = #"<c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>"# + list + "</c:calendar-multiget>"
            let (data, _, base) = try await send("REPORT", calendar, depth: "1", body: q)
            for r in try multistatus(data) {
                guard let u = href(r, base: base), let p = Self.props(r), let tag = p.first("getetag")?.text, let ics = p.first("calendar-data")?.text else { continue }
                out.append(Resource(href: u.path(percentEncoded: true), etag: tag, ics: ics))
            }
        }
        return out
    }

    /// Create (If-None-Match: *) or update (If-Match). Returns the new ETag when the server sends one.
    public func put(_ url: URL, ics: String, etag: String?) async throws -> String? {
        let (_, h, _) = try await send("PUT", url, body: ics, headers: etag.map { ["If-Match": $0] } ?? ["If-None-Match": "*"])
        return h.value(forHTTPHeaderField: "ETag")
    }

    public func delete(_ url: URL, etag: String?) async throws {
        _ = try await send("DELETE", url, headers: etag.map { ["If-Match": $0] } ?? [:])
    }

    func xmlEscape(_ s: String) -> String {
        s.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }
}
