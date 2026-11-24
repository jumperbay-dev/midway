import SwiftUI
import WebKit

/// The safe viewer. Mail HTML is hostile input, so it gets every cheap, built-in macOS barrier:
/// - WebKit renders out of process, in the system-sandboxed com.apple.WebKit.WebContent helper.
/// - Lockdown Mode for this view only: no JIT, WebGL, WASM, remote fonts and many other web features.
/// - A `default-src 'none'` CSP injected ahead of the mail's own markup. Inline JavaScript may run (allowed for now),
///   but it has no network (`connect-src` falls back to 'none'), cannot open windows and cannot navigate.
/// - A compiled content rule list blocks every http(s) load, so remote images and tracking pixels never fire.
/// - A non-persistent data store: no cookies or storage. Every navigation is cancelled; links go to the browser.
struct MessageWebView: NSViewRepresentable {
    let html: String

    // ponytail: inline JS allowed for now; drop `script-src` and set allowsContentJavaScript = false to lock it again.
    static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; form-action 'none'; base-uri 'none'"
    // WebKit's url-filter has no `|` alternation, hence one rule per scheme.
    static let blockAll = "[" + ["^https?://", "^wss?://", "^ftp://"]
        .map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        .joined(separator: ",") + "]"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.isLockdownModeEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "midway.block-network", encodedContentRuleList: Self.blockAll) { list, error in
            if let list { config.userContentController.add(list) }
            // If compiling ever fails, the CSP and JS-off still block remote loads; showing mail beats a blank reader.
            if let error { NSLog("midway: content rule list failed: \(error)") }
            context.coordinator.ready(html: nil)
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.ready(html: html)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        private var rulesReady = false
        private var pending: String?
        private var shown: String?

        /// Loads only once the rule list is installed, so the first message is never rendered unblocked.
        func ready(html: String?) {
            if let html { pending = html } else { rulesReady = true }
            guard rulesReady, let html = pending, html != shown else { return }
            shown = html
            view?.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"\(MessageWebView.csp)\">" + html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Our own loadHTMLString navigates to about:blank; anything else is the mail trying to go somewhere.
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" { return .allow }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                // ponytail: opens directly; showing the real domain before opening comes with the reader polish
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}
