import Foundation
import Testing
@testable import MidwayCore

@Test func pkceChallengeIsBase64URLOfSHA256() {
    #expect(GoogleOAuth.challenge(for: "abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
    #expect(GoogleOAuth.randomURLSafe(32).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

@Test func authorizationURLCarriesPKCEAndLoopback() throws {
    let url = GoogleOAuth.authorizationURL(GoogleClient(id: "cid", secret: "s"), redirect: "http://127.0.0.1:5000/", challenge: "ch", state: "st", loginHint: "me@gmail.com")
    let q = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value!) })
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["redirect_uri"] == "http://127.0.0.1:5000/")
    #expect(q["scope"]?.contains("https://mail.google.com/") == true)
    #expect(q["login_hint"] == "me@gmail.com")
    #expect(q["client_secret"] == nil)  // never in the browser URL
}

@Test func readsEmailFromIDToken() {
    let payload = GoogleOAuth.base64URL(Data(#"{"email":"me@gmail.com","sub":"1"}"#.utf8))
    #expect(GoogleOAuth.email(fromIDToken: "e30.\(payload).sig") == "me@gmail.com")
    #expect(GoogleOAuth.email(fromIDToken: "garbage") == nil)
}

@Test func xoauth2StringMatchesGoogleFormat() {
    #expect(AccountSync.xoauth2(user: "me@gmail.com", token: "ya29") == "user=me@gmail.com\u{1}auth=Bearer ya29\u{1}\u{1}")
}

@Test func loopbackReceivesTheRedirect() async throws {
    let got = try await GoogleOAuth.receiveRedirect { port in
        Task { _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/?state=st&code=c0de")!) }
    }
    #expect(got.uri.hasPrefix("http://127.0.0.1:"))
    #expect(got.components.queryItems?.first { $0.name == "code" }?.value == "c0de")
}

@Test func gmailLabelsReplaceOnUpdate() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try Store.open(at: dir)
    let g = try store.add(.gmail("me@gmail.com"))
    #expect(g.kind == .google && g.imapHost == "imap.gmail.com")
    _ = try store.prepareMailbox(account: g.id!, name: "[Gmail]/All Mail", uidValidity: 1)
    try store.insert(raw: Data(sample.utf8), uid: 7, state: .init(seen: false, labels: [Label.inbox, "Travel"], gmMsgId: 42, gmThrId: 43), account: g.id!, mailbox: "[Gmail]/All Mail")
    func labels() throws -> Set<String> { Set(try store.db.read { try String.fetchAll($0, sql: "SELECT name FROM label") }) }
    #expect(try labels() == [Label.inbox, "Travel"])

    // Archived elsewhere: Gmail drops \Inbox, keeps the user label.
    try store.update([7: .init(seen: true, labels: ["Travel"])], account: g.id!, mailbox: "[Gmail]/All Mail")
    #expect(try labels() == ["Travel"])
    #expect(try store.db.read { try Message.fetchOne($0)!.gmMsgId } == 42)
}
