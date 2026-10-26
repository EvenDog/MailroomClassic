// Prints an email the way classic Outlook did: the sender's name in bold at the
// top, a line, a From / Sent / To / Cc / Subject / Attachments block, then the
// message itself. It builds a printable web page, loads it into a hidden web
// view (with the same safety settings as the reading pane), and opens the
// standard macOS print dialog, which can also save as PDF.

import AppKit
import WebKit

final class MessagePrinter: NSObject, WKNavigationDelegate {
    // Keeps the printer alive while its page loads and the print dialog is open.
    // (Otherwise nothing would hold on to it and it would vanish mid-print.)
    private static var current: MessagePrinter?

    private let webView: WKWebView
    private let jobTitle: String
    private weak var window: NSWindow?

    // Prints `message` (whose downloaded contents are `contents`). The print
    // dialog slides down from `window`. Pictures from the internet are only
    // included if you clicked "Download Pictures".
    static func print(_ message: MailMessage, contents: OpenMessage, allowRemoteContent: Bool, from window: NSWindow?) {
        let printer = MessagePrinter(jobTitle: message.subject, window: window)
        current = printer
        printer.load(page(for: message, contents: contents), allowRemoteContent: allowRemoteContent)
    }

    private init(jobTitle: String, window: NSWindow?) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        // About the width of a printed page, in points (1/72 inch).
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: configuration)
        self.jobTitle = jobTitle
        self.window = window
        super.init()
        webView.navigationDelegate = self
    }

    private func load(_ html: String, allowRemoteContent: Bool) {
        Task {
            if !allowRemoteContent, let rules = await RemoteContentBlocker.rules() {
                webView.configuration.userContentController.add(rules)
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // Called by WebKit once the page has loaded: now it can be printed.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo   // a copy, so this doesn't change other apps' defaults
        printInfo.horizontalPagination = .fit     // shrink wide emails to fit the page width
        printInfo.verticalPagination = .automatic // and spread long ones over several pages
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = jobTitle
        operation.view?.frame = webView.bounds   // without a size, WebKit can print blank pages
        // Only `runModal(for:)` works for web pages: the simpler `run()` was tested and
        // got stuck printing endless pages. So with no window to attach to, don't print.
        guard let window = window ?? NSApp.keyWindow else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // Same rule as the reading pane: the page may not navigate anywhere else.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == "about" || navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel
    }

    // MARK: - Building the page

    // The printable page: an Outlook-style header followed by the message body.
    static func page(for message: MailMessage, contents: OpenMessage) -> String {
        var rows: [(label: String, value: String)] = [
            ("From:", message.sender.formatted),
            ("Sent:", message.dateReceived.formatted(date: .complete, time: .shortened)),
            ("To:", message.toRecipients.map(\.formatted).joined(separator: "; ")),
        ]
        if !message.ccRecipients.isEmpty {
            rows.append(("Cc:", message.ccRecipients.map(\.formatted).joined(separator: "; ")))
        }
        rows.append(("Subject:", message.subject))
        if !contents.attachments.isEmpty {
            rows.append(("Attachments:", contents.attachments.map(\.filename).joined(separator: "; ")))
        }
        let headerRows = rows.map { "<tr><th>\(escape($0.label))</th><td>\(escape($0.value))</td></tr>" }.joined()

        // An HTML email goes in as it is; plain text keeps its line breaks.
        let body = contents.html ?? "<div class=\"plain\">\(escape(contents.plainText))</div>"

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><style>
        .mailroom-header { font-family: Helvetica, Arial, sans-serif; font-size: 10pt; color: black; margin-bottom: 16px; }
        .mailroom-header .name { font-size: 13pt; font-weight: bold; border-bottom: 3px solid black; padding-bottom: 4px; margin-bottom: 8px; }
        .mailroom-header th { text-align: left; vertical-align: top; padding: 1px 12px 1px 0; white-space: nowrap; }
        .mailroom-header td { padding: 1px 0; }
        .plain { white-space: pre-wrap; font-family: Helvetica, Arial, sans-serif; font-size: 10pt; color: black; }
        </style></head><body>
        <div class="mailroom-header">
        <div class="name">\(escape(message.senderDisplayName))</div>
        <table>\(headerRows)</table>
        </div>
        \(body)
        </body></html>
        """
    }

    // Makes text safe to put in a web page, so a subject like "<b>Hi</b>" prints as typed.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
