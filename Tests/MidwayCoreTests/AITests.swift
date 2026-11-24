import Foundation
import GRDB
import Testing
@testable import MidwayCore

/// A stand-in for the claude binary: answers --version and auth status, and streams back what stdin asks for.
func fakeEngine() throws -> (path: String, dir: URL) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = """
        #!/bin/sh
        case "$1" in
          --version) echo "2.1.325 (Claude Code)"; exit 0;;
          auth) echo '{"loggedIn": true}'; exit 0;;
        esac
        input=$(cat)
        say() {
          echo '{"type":"system","subtype":"init"}'
          echo "{\\"type\\":\\"stream_event\\",\\"event\\":{\\"type\\":\\"content_block_delta\\",\\"delta\\":{\\"type\\":\\"text_delta\\",\\"text\\":\\"$1\\"}}}"
          echo "{\\"type\\":\\"result\\",\\"subtype\\":\\"success\\",\\"is_error\\":false,\\"result\\":\\"$1\\",\\"total_cost_usd\\":0.01}"
        }
        case "$input" in
          *SLEEP*) exec sleep 30;;
          *ENV*) say "secret=$MIDWAY_SECRET files=$(ls -A | wc -l | tr -d ' ') user=$USER";;
          *BADJSON*)
            n="$(dirname "$0")/n"
            if [ -f "$n" ]; then say '{\\"tags\\": [\\"Travel\\"], \\"rule\\": null}'; else touch "$n"; say "no json here"; fi;;
          *) say "hello";;
        esac
        """
    let path = dir.appending(path: "claude").path
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return (path, dir)
}

func request(_ context: String) -> AIRequest {
    AIRequest(task: "test", instructions: "Test.", context: context, messages: 1)
}

@Test func detectsAndStreams() async throws {
    let (path, dir) = try fakeEngine()
    defer { try? FileManager.default.removeItem(at: dir) }
    let d = await Engine.claude.detect(override: path)
    #expect(d.version == "2.1.325" && d.loggedIn && d.ready)
    #expect(await Engine.claude.detect(override: "/nonexistent/claude").problem?.contains("not installed") == true)

    let (store, _, sdir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: sdir) }
    let runner = AIRunner(store: store)
    await runner.configure(path: path, version: d.version, model: "")
    let deltas = Locked([String]())
    let r = try await runner.run(request("hi")) { t in deltas.update { $0.append(t) } }
    #expect(r.text == "hello" && r.cost == 0.01)
    #expect(deltas.value == ["hello"])

    // No mail secrets in the environment, an empty working folder, and the sign-in still found.
    setenv("MIDWAY_SECRET", "hunter2", 1)
    let env = try await runner.run(request("ENV"))
    #expect(env.text == "secret= files=0 user=\(NSUserName())")

    // The run log has sizes, never content.
    let runs = try store.runs()
    #expect(runs.count == 2 && runs.allSatisfy { $0.outcome == "ok" && $0.bytes > 0 })
}

@Test func cancelsAndRetriesDecoding() async throws {
    let (path, dir) = try fakeEngine()
    defer { try? FileManager.default.removeItem(at: dir) }
    let runner = AIRunner(store: nil)
    await runner.configure(path: path, version: "2.1.325", model: "haiku")

    let started = Date.now
    let task = Task { try await runner.run(request("SLEEP")) }
    try await Task.sleep(for: .milliseconds(300))
    await #expect(throws: AIError.busy) { try await runner.run(request("hi")) }  // one run at a time
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(Date.now.timeIntervalSince(started) < 5)

    // The first answer is not JSON; the retry is.
    let s = try await runner.ask(request("BADJSON"), as: AI.TagSuggestion.self)
    #expect(s == AI.TagSuggestion(tags: ["Travel"], rule: nil))
}

@Test func promptsStripAndRedact() {
    let text = "Sounds good, call me on +49 170 1234567.\n\nOn Mon, Ada <ada@example.com> wrote:\n> Dinner?\n> Friday"
    #expect(AI.strip(text) == "Sounds good, call me on +49 170 1234567.")
    #expect(AI.redact("Mail ada@example.com or call +49 170 1234567") == "Mail [email] or call [phone]")
    let r = AI.summarise([AI.Mail(from: "Ada", date: .now, text: "Write to jo@x.io\n> old")], redact: true)
    #expect(r.context.contains("[email]") && !r.context.contains("jo@x.io") && !r.context.contains("old"))
    #expect(r.preview.contains("addresses redacted"))
    let fenced: AI.Summary = try! AI.decode("```json\n{\"summary\":[\"a\"],\"asks\":[],\"event\":null}\n```")
    #expect(fenced.summary == ["a"] && fenced.event == nil)
}

@Test func threadAndAccountSwitch() throws {
    let (store, a, dir) = try tempStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(try store.accounts().first?.ai == false)  // off until turned on
    try store.setAI(a, true)
    #expect(try store.accounts().first?.ai == true)
    for (uid, subject) in [(1, "Dinner on Friday?"), (2, "Re: Dinner on Friday?"), (3, "Something else")] {
        try store.insert(raw: eml("ada@example.com", "me@fastmail.com", subject, "Body \(uid)", extra: "Message-ID: <\(uid)@x>\r\n"),
                         uid: Int64(uid), state: .init(seen: false, labels: [Label.inbox]), account: a, mailbox: "INBOX")
    }
    let m = try store.db.read { try Message.filter(Column("uid") == 2).fetchOne($0)! }
    #expect(try store.thread(m).map(\.text) == ["Body 1", "Body 2"])
}

@Test func eventAsICS() throws {
    let e = AI.Event(title: "Dinner, harbour", start: "2026-11-28T19:30:00+01:00", end: nil, location: "Harbour; Bergen")
    let ics = try #require(e.ics(now: Date(timeIntervalSince1970: 0)))
    #expect(ics.contains("DTSTART:20261128T183000Z\r\nDTEND:20261128T193000Z\r\n"))
    #expect(ics.contains("SUMMARY:Dinner\\, harbour") && ics.contains("LOCATION:Harbour\\; Bergen"))
    #expect(AI.Event(title: "x", start: "Friday", end: nil, location: nil).ics() == nil)
}
