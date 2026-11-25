# midway

Native macOS mail client in Swift, built from the *midway screens* canvas (Atlantis dark) and the *midway: design* doc.
Done so far:

1. **Reader (Fastmail)**: app-password sign-in, Keychain, GRDB store with content-addressed `.eml` blobs,
   INBOX sync (newest 200) with IDLE, sidebar + list + sandboxed HTML reader.
2. **Gmail**: Google sign-in in the browser (OAuth with PKCE, loopback redirect), IMAP `XOAUTH2`,
   All Mail sync with `X-GM-MSGID`/`X-GM-THRID`/`X-GM-LABELS`, labels as sidebar folders, one unified Inbox.
3. **Daily driver**: offline queue (archive `e`, delete `#`, star `s`, read/unread `u`, undo `⌘Z`), deletions found by UID check,
   compose window (`c`, reply `r`) with rich text, address autocomplete, local drafts, outbox with 10-second undo send over SMTP
   (implicit TLS, `AUTH PLAIN` or `XOAUTH2`) and retries, FTS5 search (`/`) with server fallback on return, and an address book
   built from received and sent mail.

   Not yet: Drafts saved to the server's Drafts folder, Fastmail Archive/Trash views (only INBOX syncs there),
   backfill beyond the newest 200, lists/quotes/images in the composer.
4. **Triage**: local piles: Reply later (`l`), Set aside (`y`), snooze (`h`) with presets or typed times
   ("fri 9am", "in 3 days"), brought back early when someone replies. Focus and reply (`⌘.`) works through Reply later
   with reply-all drafts and Send and next (`⌘↩`). Command bar (`⌘K`), keyboard map (`?`), `g i` for the Inbox, and a
   Dock badge with Inbox unread.

   Not yet: "When I'm free" and travel-based snoozes, key rebinding, Claude in Focus, piles synced across Macs.
5. **Tags and Screener**: one query syntax for search and rules (`from:` `domain:` `via:` `list:` `subject:` `tag:`
   `is:unread|starred|known` `older:30d`, words, `OR`, `NOT`/`-`, brackets). Local tags (`t`, never sent to a server,
   kept by Message-ID) with rules that tag new mail and can re-run on old mail. The Screener holds first-time senders
   (`y` allow, `n` block, `t` allow and tag; `g s`), with "always let through" rules. Each message knows which of your
   addresses it reached ("via shop+"), shown as a chip and as a Via section in the sidebar. Tags, rules and Screener
   decisions export to JSON and import on another Mac.

   Not yet: leak watch and the Via settings page, rule actions beyond tag and allow (mark read, archive),
   `has:attachment` / `header:` terms, AI-suggested tags.
6. **Quick access**: a local extractor (patterns only, no AI, no network) finds one-time codes, parcels (UPS, DHL,
   DPD, GLS, Hermes, FedEx, postal S10 numbers, "track your parcel" links), key links (verify, confirm, reset password,
   unsubscribe including `List-Unsubscribe`, join meeting) and booking or order numbers. The reader shows a code banner
   for 15 minutes with Copy, tracking and link buttons with the real domain (opened in the browser), and copy chips.
   Rows show a delivery chip; the command bar has "Copy code" and Deliveries (cleared by a "delivered" mail or after
   30 days). Go ▸ Copy Latest Code is ⌥⌘C; codes go to the pasteboard marked concealed.

   Not yet: a system-wide shortcut for the latest code, "Find things in this mail" with AI, unwrapping tracking redirects.
7. **Claude**: AI through the `claude` CLI you already have. midway holds no keys. Settings ▸ AI engines (`⌘,`) finds
   the binary through your login shell (or a path you choose), checks the version and the sign-in, runs a test on a
   built-in sample, previews exactly what would be sent, and turns AI on per account. It is off for every account until
   you turn it on. In the reader, `a` (or Ask AI) pins a thread summary with "Asked of you" to-dos and, when a date is
   settled, "Add to calendar" (the event editor, filled in and marked, nothing saved until you save). Esc stops a run. In a reply, a one-line intent and Draft stream a
   suggestion; Polish, Shorter and Warmer rewrite it. Nothing reaches the body until Use draft (`⌘⇧↩`). The tag
   picker can suggest tags and a rule. Each run gets the prompt on stdin, an empty temporary folder and only `PATH`,
   `HOME`, `LANG` and `USER`, with tools, MCP servers, settings files and session saving off, and a 60 s timeout.
   Addresses and phone numbers are redacted by default. The run log keeps task, size, time and cost, never content.

   Not yet: Codex and a default engine per action, "Ask your mail", Claude in Focus and reply, AI in the Screener.
8. **Calendars**: CalDAV for Fastmail (same app password; it needs calendar access) and Google (same sign-in; accounts
   added before this version sign in again once for the calendar scope). Calendar mode is `⌘2`, Mail `⌘1`, or the
   switch at the top of the sidebar. Day, week (48 pt an hour, overlapping events side by side, a now line), month and
   a 60-day agenda; the sidebar has a mini month, Up next, calendars by account with a colour and an eye, and the sync
   state. Quick add ("Lunch with Ada thu 12 /work") is parsed on the Mac, no AI; return saves, shift-return opens the
   editor. The editor side panel saves with `⌘S`, or "Save and invite" with you as organiser so the server sends the
   invitations. Edits PUT with `If-Match` and keep every line midway doesn't edit (descriptions, alarms); a 412 refetches
   and says so. Repeating events keep their times. Calendars poll every 5 minutes, when midway comes to the front and
   after an edit. Invitations in mail show a card with Accept, Maybe and Decline, the calendar to add to and clashes;
   answers go through the server's copy when it has one, else the event is added and an iCalendar REPLY goes out by mail.

   Not yet: sync-collection tokens, an offline queue for calendar edits (an edit fails while offline), BYMONTHDAY and
   other rarer repeat rules, editing one occurrence of a series, free/busy lookup, tags on events, "Found in your mail".

9. **Ship**: themes from the canvas in Settings ▸ Appearance (`⌘,`): Deep (Atlantis dark, the default), Pier (Atlantis
   light) and Follow system. Sparkle 2.10.1 checks an EdDSA-signed appcast (midway ▸ Check for Updates…; off in dev
   builds, which have no feed). `scripts/release.sh <version>` signs Sparkle's helpers and the app with your Developer
   ID and the hardened runtime, notarizes with `notarytool`, staples, zips and writes `appcast.xml`, all on your Mac.

   Not yet: the data-protection Keychain (needs a Developer ID provisioning profile), accent and density settings,
   delta updates, a DMG.

Builds with the Command Line Tools alone (no Xcode, no CI).

```sh
swift build                 # debug build
./scripts/bundle.sh         # build/midway.app, ad-hoc signed (hardened runtime only in release.sh)
open build/midway.app
```

Tests (the Testing macro plugin path is needed without Xcode):

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Gmail needs a Google Cloud OAuth client of type *Desktop app* (Gmail API enabled, consent screen with the
`https://mail.google.com/` and `https://www.googleapis.com/auth/calendar` scopes, the CalDAV API enabled,
your address as a test user). Put its ID and secret in a git-ignored file:

```sh
cp config/Google.example.xcconfig config/Google.xcconfig   # then fill in both values
./scripts/bundle.sh                                         # copies them into Info.plist
```

Releases need, once: a `Developer ID Application` certificate, `xcrun notarytool store-credentials midway-notary`
(Apple ID with an app-specific password), and `.build/artifacts/sparkle/Sparkle/bin/generate_keys` for the update key.
Then fill in `config/Release.xcconfig` (git-ignored, from the example) and run:

```sh
scripts/release.sh 0.2.0    # build/release/midway-0.2.0.zip and appcast.xml, to upload next to the feed URL
```

For `swift run`, set `MIDWAY_GOOGLE_CLIENT_ID` and `MIDWAY_GOOGLE_CLIENT_SECRET` instead.

Local test servers: GreenMail (IMAP 3143, SMTP 3025) and Radicale (CalDAV 5232) in Docker, with a throwaway account.
Plaintext is allowed only for `localhost` and only with `MIDWAY_DEV_PLAINTEXT=1`; the password comes from
`MIDWAY_DEV_PASSWORD` so the test account needs no Keychain item.

```sh
docker run -d --name midway-greenmail -p 3025:3025 -p 3143:3143 \
  -e GREENMAIL_OPTS='-Dgreenmail.setup.test.smtp -Dgreenmail.setup.test.imap -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.users=me:devpass@local.test,ada:devpass@local.test -Dgreenmail.users.login=email' \
  greenmail/standalone
docker run -d --name midway-radicale -p 5232:5232 tomsquest/docker-radicale
curl -u me@local.test:devpass -X MKCALENDAR http://localhost:5232/me@local.test/personal/
mkdir -p /tmp/midway-local && sqlite3 /tmp/midway-local/midway.sqlite \
  "insert into account(email, imapHost, imapPort, kind, ai) values('me@local.test','localhost',993,'password',0)"  # after a first launch
open -n build/midway.app --env MIDWAY_HOME=/tmp/midway-local --env MIDWAY_DEV_PLAINTEXT=1 --env MIDWAY_DEV_PASSWORD=devpass
```

Dev store: `MIDWAY_HOME=/tmp/midway-dev swift run Seed /tmp/midway-dev` seeds sample mail, calendars and an invitation; launch with the same `MIDWAY_HOME`.

## Security

- **Network**: IMAP over TLS only (`swift-nio-imap` → NIOSSL, full certificate and hostname verification).
- **Sending**: SMTP over TLS on 465 through Network.framework (system trust, hostname checked). Outgoing HTML is generated
  from bold, italic and http(s)/mailto links only.
- **Secrets**: app password or Google refresh token in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced), never in SQLite. Google access tokens live in memory only.
- **Mail HTML** renders in `WKWebView`, which runs in Apple's sandboxed `WebContent` process, with Lockdown Mode on
  for that view, inline JavaScript allowed for now (no network, windows or navigation), a `default-src 'none'` CSP, a content rule list blocking all http(s)/ws/ftp loads,
  a non-persistent data store, and every navigation cancelled (links open in the browser).

Dependencies are pinned to exact versions: GRDB 7.12.0, swift-nio-imap 0.5.0.
