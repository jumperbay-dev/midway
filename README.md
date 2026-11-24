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

Builds with the Command Line Tools alone (no Xcode, no CI).

```sh
swift build                 # debug build
./scripts/bundle.sh         # build/midway.app, ad-hoc signed, hardened runtime
open build/midway.app
```

Tests (the Testing macro plugin path is needed without Xcode):

```sh
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Gmail needs a Google Cloud OAuth client of type *Desktop app* (Gmail API enabled, consent screen with the
`https://mail.google.com/` scope, your address as a test user). Put its ID and secret in a git-ignored file:

```sh
cp config/Google.example.xcconfig config/Google.xcconfig   # then fill in both values
./scripts/bundle.sh                                         # copies them into Info.plist
```

For `swift run`, set `MIDWAY_GOOGLE_CLIENT_ID` and `MIDWAY_GOOGLE_CLIENT_SECRET` instead.

Dev store: `MIDWAY_HOME=/tmp/midway-dev swift run Seed /tmp/midway-dev` seeds sample mail; launch with the same `MIDWAY_HOME`.

## Security

- **Network**: IMAP over TLS only (`swift-nio-imap` → NIOSSL, full certificate and hostname verification).
- **Sending**: SMTP over TLS on 465 through Network.framework (system trust, hostname checked). Outgoing HTML is generated
  from bold, italic and http(s)/mailto links only.
- **Secrets**: app password or Google refresh token in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced), never in SQLite. Google access tokens live in memory only.
- **Mail HTML** renders in `WKWebView`, which runs in Apple's sandboxed `WebContent` process, with Lockdown Mode on
  for that view, inline JavaScript allowed for now (no network, windows or navigation), a `default-src 'none'` CSP, a content rule list blocking all http(s)/ws/ftp loads,
  a non-persistent data store, and every navigation cancelled (links open in the browser).

Dependencies are pinned to exact versions: GRDB 7.12.0, swift-nio-imap 0.5.0.
