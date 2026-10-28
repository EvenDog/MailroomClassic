// Unsubscribing from mailing lists. Most newsletters carry a hidden
// `List-Unsubscribe` header line saying how to leave the list: a web link, an
// email address to write to, or both. If they also send `List-Unsubscribe-Post`,
// the web link is "one-click": a single background request unsubscribes you
// (the standard for this is called RFC 8058). The reading pane's Unsubscribe
// button uses the best way the email offers.

import Foundation

enum UnsubscribeMethod: Equatable {
    case oneClick(URL)                                   // a background web request does it all
    case email(to: String, subject: String, body: String)   // Mailroom sends an email for you
    case webPage(URL)                                    // opens their unsubscribe page in your browser

    // The two header lines to ask the server for (see IMAPService.fetchUnsubscribeMethod).
    static let headerNames = ["List-Unsubscribe", "List-Unsubscribe-Post"]

    // Works out the best method from the two header lines, or nil if there's no usable one.
    // `listUnsubscribe` looks like: <mailto:leave@list.com?subject=unsubscribe>, <https://list.com/u/123>
    init?(listUnsubscribe: String, listUnsubscribePost: String?) {
        // Each choice sits between < and >. Splitting on "<" and keeping what's
        // before each ">" gives just the links.
        let links = listUnsubscribe.split(separator: "<").compactMap { piece -> URL? in
            guard let end = piece.firstIndex(of: ">") else { return nil }
            return URL(string: piece[..<end].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let webLinks = links.filter { $0.scheme?.lowercased() == "https" || $0.scheme?.lowercased() == "http" }
        let emailLinks = links.filter { $0.scheme?.lowercased() == "mailto" }
        // The standard only allows one-click for https links.
        let isOneClick = listUnsubscribePost?.localizedCaseInsensitiveContains("List-Unsubscribe=One-Click") == true

        if isOneClick, let link = webLinks.first(where: { $0.scheme?.lowercased() == "https" }) {
            self = .oneClick(link)
        } else if let link = emailLinks.first,
                  // URLComponents splits "mailto:leave@list.com?subject=x" into the address ("path") and the "?…" part.
                  let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
                  !parts.path.isEmpty {
            let query = parts.queryItems ?? []
            func value(_ name: String) -> String? {
                query.first { $0.name.lowercased() == name }?.value
            }
            self = .email(to: parts.path, subject: value("subject") ?? "unsubscribe", body: value("body") ?? "unsubscribe")
        } else if let link = webLinks.first {
            self = .webPage(link)
        } else {
            return nil
        }
    }

    // The one-click request: an HTTP "POST" (sending data to a web address) with
    // the exact text the standard asks for. Throws if their server says no.
    static func unsubscribeWithOneClick(at url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        // 200–299 means "OK" in HTTP. Anything else is a refusal or an error page.
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw MailError(message: "The mailing list's website answered with error \(status).")
        }
    }
}
