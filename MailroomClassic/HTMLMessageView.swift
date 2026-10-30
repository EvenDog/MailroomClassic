// Shows an HTML email using WebKit (the engine behind Safari), with safety
// settings for email: JavaScript is off, nothing is saved between messages,
// links open in your normal browser, and pictures from the internet are blocked
// unless you click "Download Pictures" (senders use them to track when you read mail).
// It also reports the link under the mouse, and asks before opening a link whose
// text pretends to go to a different site (see LinkSafety).

import SwiftUI
import WebKit

// SwiftUI has no built-in web view on the Mac, so this wraps AppKit's WKWebView.
// `NSViewRepresentable` is the bridge for putting an AppKit view inside SwiftUI.
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    let zoom: Double   // 1 = normal size, 1.5 = 50% bigger
    @Binding var hoveredLink: LinkSafety.HoveredLink?   // the link under the mouse, or nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()   // no cookies or cache kept
        // LinkSafety's script runs in its own content world: a separate space for the app's
        // scripts that the email can't see or touch, and that still runs with the email's
        // JavaScript off. Its messages arrive in the coordinator under the name "links".
        let linksWorld = WKContentWorld.world(name: "MailroomLinks")
        configuration.userContentController.add(context.coordinator, contentWorld: linksWorld, name: "links")
        configuration.userContentController.addUserScript(
            WKUserScript(source: LinkSafety.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: linksWorld))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    // Called whenever SwiftUI redraws; only reloads if the email or the picture setting changed.
    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.pageZoom = zoom   // the same as Safari's View → Zoom In / Zoom Out
        let coordinator = context.coordinator
        coordinator.showHoveredLink = { hoveredLink = $0 }
        guard coordinator.loadedHTML != html || coordinator.loadedAllowRemoteContent != allowRemoteContent else { return }
        coordinator.loadedHTML = html
        coordinator.loadedAllowRemoteContent = allowRemoteContent
        coordinator.pretendingLinks = [:]   // the new email's script sends its own list
        DispatchQueue.main.async { hoveredLink = nil }   // after this redraw: SwiftUI doesn't allow changes during one

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

    // Decides what happens when the page tries to go somewhere, e.g. a clicked link,
    // and receives LinkSafety's messages from inside the email.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedHTML: String?
        var loadedAllowRemoteContent: Bool?
        var showHoveredLink: (LinkSafety.HoveredLink?) -> Void = { _ in }
        // Links in the shown email whose text pretends to be another site: address → that site.
        var pretendingLinks: [String: String] = [:]

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                // A link whose text shows a different site: ask first.
                if let pretendedSite = pretendingLinks[url.absoluteString],
                   !LinkSafety.confirmOpening(url, pretendedSite: pretendedSite) {
                    return .cancel
                }
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

        // A message from LinkSafety's script: the email's links once it has loaded,
        // or the link the mouse just moved onto (or off, as null).
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // JavaScript objects arrive as dictionaries, and its lists as arrays.
            guard let body = message.body as? [String: Any] else { return }
            if let links = body["links"] as? [[String]] {
                for link in links where link.count == 2 {
                    if let url = URL(string: link[1]), let site = LinkSafety.pretendedSite(text: link[0], realAddress: url) {
                        pretendingLinks[url.absoluteString] = site
                    }
                }
            }
            if body.keys.contains("hover") {
                let address = body["hover"] as? String   // nil when the mouse left a link (JavaScript's null)
                showHoveredLink(address.map { LinkSafety.HoveredLink(address: $0, pretendedSite: pretendingLinks[$0]) })
            }
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
