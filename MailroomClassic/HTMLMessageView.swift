// Shows an HTML email using WebKit (the engine behind Safari), with safety
// settings for email: JavaScript is off, nothing is saved between messages,
// links open in your normal browser, and pictures from the internet are blocked
// unless you click "Download Pictures" (senders use them to track when you read mail).

import SwiftUI
import WebKit

// SwiftUI has no built-in web view on the Mac, so this wraps AppKit's WKWebView.
// `NSViewRepresentable` is the bridge for putting an AppKit view inside SwiftUI.
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowRemoteContent: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()   // no cookies or cache kept
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    // Called whenever SwiftUI redraws; only reloads if the email or the picture setting changed.
    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.loadedHTML != html || coordinator.loadedAllowRemoteContent != allowRemoteContent else { return }
        coordinator.loadedHTML = html
        coordinator.loadedAllowRemoteContent = allowRemoteContent

        let contentController = webView.configuration.userContentController
        contentController.removeAllContentRuleLists()
        if allowRemoteContent {
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            // The blocking rules load asynchronously; the email loads once they're in place.
            Task {
                if let rules = await RemoteContentBlocker.rules() {
                    contentController.add(rules)
                }
                // Only load if this is still the email we were asked to show.
                if coordinator.loadedHTML == html {
                    webView.loadHTMLString(html, baseURL: nil)
                }
            }
        }
    }

    // Decides what happens when the page tries to go somewhere, e.g. a clicked link.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?
        var loadedAllowRemoteContent: Bool?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)   // open links in your default browser
                return .cancel
            }
            // The email itself loads as "about:blank". Refuse anything that tries to replace
            // it with another page (e.g. an automatic redirect hidden in the email).
            if navigationAction.targetFrame?.isMainFrame == true, navigationAction.request.url?.scheme != "about" {
                return .cancel
            }
            return .allow
        }
    }
}

// Builds (once) the WebKit rule that blocks every http:// and https:// request.
enum RemoteContentBlocker {
    private static var compiledRules: WKContentRuleList?

    static func rules() async -> WKContentRuleList? {
        if let compiledRules { return compiledRules }
        let json = #"[{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}}]"#   // #"..."# = raw string, no escaping needed
        compiledRules = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "BlockRemoteContent", encodedContentRuleList: json)
        return compiledRules
    }

    // Rough check for whether an email tries to load anything from the internet,
    // so we only show the "Download Pictures" bar when it would do something.
    static func hasRemoteContent(_ html: String) -> Bool {
        html.range(of: #"(?i)(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?\s*https?:"#,
                   options: .regularExpression) != nil
    }
}
