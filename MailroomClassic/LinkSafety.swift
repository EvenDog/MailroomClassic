// Link safety for HTML emails. A common scam trick is a link whose text shows one
// web address ("www.paypal.com") but that really goes to another site. So:
// hovering over a link shows its real address in a small bar at the bottom of the
// reading pane (like Safari), and clicking a link whose text pretends to be a
// different site asks before opening it.
//
// To know where the mouse is and what each link's text says, a small script runs
// inside the email. Emails' own JavaScript stays off: this script runs in a separate,
// sealed-off "content world" that only the app can use (see HTMLMessageView).

import AppKit
import SwiftUI

enum LinkSafety {
    // The link under the mouse, for the bar at the bottom.
    struct HoveredLink: Equatable {
        let address: String
        let pretendedSite: String?   // set if the link's text shows a different site
    }

    // If a link's `text` reads like a web address (e.g. "www.paypal.com" or
    // "https://paypal.com/login") on a different site from where the link really
    // goes, returns the site the text shows ("www.paypal.com"). Otherwise nil.
    static func pretendedSite(text: String, realAddress: URL) -> String? {
        guard let scheme = realAddress.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let realSite = realAddress.host()?.lowercased() else { return nil }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Only text that looks like a web address counts, so "Read more" or "report.pdf" don't.
        guard !text.isEmpty, !text.contains(" "), !text.contains("@"),
              text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www.") || endsInCommonDomain(text),
              let shownSite = URL(string: text.contains("://") ? text : "https://" + text)?.host()?.lowercased(),
              shownSite.contains(".") else { return nil }
        // Different addresses on the same main site ("www.paypal.com" and "paypal.com",
        // or "store.apple.com" and "www.apple.com") are fine.
        return mainSite(of: realSite) == mainSite(of: shownSite) ? nil : shownSite
    }

    // The part of a site name its owner registered: "store.apple.com" → "apple.com",
    // "news.bbc.co.uk" → "bbc.co.uk". A rough rule: the last two parts, or the last three
    // when the ending is two letters with a short part before it (like .co.uk or .com.au).
    private static func mainSite(of host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let ending = parts[parts.count - 1], beforeEnding = parts[parts.count - 2]
        let partCount = ending.count == 2 && beforeEnding.count <= 3 ? 3 : 2
        return parts.suffix(partCount).joined(separator: ".")
    }

    // Whether text like "paypal.com/login" ends its site name with a common ending such as .com.
    private static func endsInCommonDomain(_ text: String) -> Bool {
        let site = text.split(separator: "/").first ?? ""
        let ending = site.split(separator: ".").last.map(String.init) ?? ""
        return site.contains(".") && commonEndings.contains(ending)
    }

    private static let commonEndings: Set<String> = [
        "com", "net", "org", "edu", "gov", "io", "co", "us", "uk", "ca", "au", "de", "fr",
        "app", "me", "info", "biz", "ai", "dev",
    ]

    // Asks before opening a link whose text pretends to be another site. Returns true
    // to open it. "Don't Open" is the default button, so pressing Return is the safe choice.
    static func confirmOpening(_ url: URL, pretendedSite: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This link doesn't go where it says"
        alert.informativeText = """
            The link's text shows \(pretendedSite), but it really goes to \(url.host() ?? url.absoluteString).

            Newsletters sometimes send clicks through a tracking service, which looks like this too. \
            But scam emails use the same trick to send you to fake sign-in pages. Only open it if you trust this email.
            """
        alert.addButton(withTitle: "Don't Open")   // the first button is the default
        alert.addButton(withTitle: "Open Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // The script that runs inside each HTML email. It sends the app two kinds of message:
    // { links: [[text, address], …] } once the email has loaded, and
    // { hover: address or null } whenever the mouse moves onto or off a link.
    static let script = """
        (() => {
          const post = (message) => window.webkit.messageHandlers.links.postMessage(message);
          post({ links: [...document.querySelectorAll('a[href]')].map((link) => [link.textContent, link.href]) });
          let current = null;
          document.addEventListener('mouseover', (event) => {
            const link = event.target.closest ? event.target.closest('a[href]') : null;
            const address = link ? link.href : null;
            if (address !== current) { current = address; post({ hover: address }); }
          });
          document.addEventListener('mouseout', (event) => {
            if (!event.relatedTarget && current !== null) { current = null; post({ hover: null }); }
          });
        })();
        """
}

// The small bar at the bottom of the reading pane showing where the link under the
// mouse really goes, with a warning when its text pretends to be another site.
struct LinkAddressBar: View {
    let link: LinkSafety.HoveredLink

    var body: some View {
        HStack(spacing: 4) {
            if let pretendedSite = link.pretendedSite {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Not \(pretendedSite):")
                    .fontWeight(.semibold)
            }
            Text(link.address)
                .lineLimit(1)
                .truncationMode(.middle)   // long addresses lose their middle, keeping the site and the end
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .padding(6)
        .allowsHitTesting(false)   // clicks go through to the email underneath
    }
}
