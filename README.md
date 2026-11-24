# midway

Native macOS mail client in Swift, built from the *midway screens* canvas (Atlantis dark) and the *midway: design* doc.
Done so far:

1. **Reader (Fastmail)**: app-password sign-in, Keychain, GRDB store with content-addressed `.eml` blobs,
   INBOX sync (newest 200) with IDLE, sidebar + list + sandboxed HTML reader.
2. **Gmail**: Google sign-in in the browser (OAuth with PKCE, loopback redirect), IMAP `XOAUTH2`,
   All Mail sync with `X-GM-MSGID`/`X-GM-THRID`/`X-GM-LABELS`, labels as sidebar folders, one unified Inbox.

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
- **Secrets**: app password or Google refresh token in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced), never in SQLite. Google access tokens live in memory only.
- **Mail HTML** renders in `WKWebView`, which runs in Apple's sandboxed `WebContent` process, with Lockdown Mode on
  for that view, inline JavaScript allowed for now (no network, windows or navigation), a `default-src 'none'` CSP, a content rule list blocking all http(s)/ws/ftp loads,
  a non-persistent data store, and every navigation cancelled (links open in the browser).

Dependencies are pinned to exact versions: GRDB 7.12.0, swift-nio-imap 0.5.0.
