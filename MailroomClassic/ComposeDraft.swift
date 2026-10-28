// The contents of a compose window (From, To, Cc, Subject, body), plus helpers
// that pre-fill one for Reply, Reply All and Forward (quoting the original
// message the way classic Outlook did), and for email links clicked elsewhere (mailto:).

import Foundation

// `Codable` and `Hashable` are required so SwiftUI can hand a draft to a new window.
struct ComposeDraft: Codable, Hashable {
    var id = UUID()            // makes every draft unique, so each opens its own window
    var accountID: UUID?       // which account to send from
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""              // plain text
    var htmlBody: String?      // formatted version, if there is one (e.g. a saved draft being edited)
    var inReplyTo: String?     // Message-ID of the email being replied to (keeps conversations threaded)
    var references: [String] = []
    var attachmentURLs: [URL] = []   // files on disk to attach
    var savedDraftUID: UInt32?       // if this draft is saved in the Drafts folder, its server ID
    // True when an email comes back after Undo Send or a failed send: it already
    // has its signature, and closing it should still ask whether to save it.
    var isReopened = false
    var sendError: String?           // why sending failed, shown when it's reopened
}

extension ComposeDraft {
    // Pre-fills a reply. Reply goes to the sender only; Reply All also copies
    // everyone else who was on the original (except you).
    static func reply(to message: MailMessage, body: String, account: AccountSettings, replyAll: Bool) -> ComposeDraft {
        let replyTargets = message.replyTo.isEmpty ? [message.sender] : message.replyTo

        var ccList: [MailAddress] = []
        if replyAll {
            // Lowercased addresses we've already used, so nobody is listed twice.
            var alreadyIncluded = Set(replyTargets.map { $0.address.lowercased() })
            alreadyIncluded.insert(account.emailAddress.lowercased())
            for person in message.toRecipients + message.ccRecipients
            where !alreadyIncluded.contains(person.address.lowercased()) {
                ccList.append(person)
                alreadyIncluded.insert(person.address.lowercased())
            }
        }

        return ComposeDraft(
            accountID: account.id,
            to: addressList(replyTargets),
            cc: addressList(ccList),
            subject: subject(message.subject, withPrefix: "RE:", unlessStartsWith: ["re:"]),
            body: originalMessageBlock(message, body: body),
            inReplyTo: message.messageID,
            references: message.references + [message.messageID].compactMap { $0 }   // compactMap drops nil
        )
    }

    // Pre-fills a forward: no recipients yet, original message quoted below,
    // and the original's attachments (already saved as files) attached again.
    static func forward(_ message: MailMessage, body: String, attachmentURLs: [URL], account: AccountSettings) -> ComposeDraft {
        ComposeDraft(
            accountID: account.id,
            subject: subject(message.subject, withPrefix: "FW:", unlessStartsWith: ["fw:", "fwd:"]),
            body: originalMessageBlock(message, body: body),
            attachmentURLs: attachmentURLs
        )
    }

    // Re-opens a saved draft for editing. Saving or sending it again replaces the saved copy.
    static func editing(_ message: MailMessage, contents: OpenMessage, attachmentURLs: [URL], account: AccountSettings) -> ComposeDraft {
        ComposeDraft(
            accountID: account.id,
            to: addressList(message.toRecipients),
            cc: addressList(message.ccRecipients),
            subject: message.subject == "(No subject)" ? "" : message.subject,
            body: contents.plainText,
            htmlBody: contents.html,
            attachmentURLs: attachmentURLs,
            savedDraftUID: message.uid
        )
    }

    // Pre-fills a new email from an email link clicked in another app or a website,
    // e.g. "mailto:sam@example.com?subject=Hello&cc=pat@example.com&body=Hi".
    // Returns nil if it isn't a mailto: link. (Bcc isn't supported, so it's ignored.)
    static func fromMailtoLink(_ url: URL) -> ComposeDraft? {
        // URLComponents splits a link into its parts and undoes %-encoding (e.g. "%20" → a space).
        guard url.scheme?.lowercased() == "mailto",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // The part after "?" is "name=value" pairs. Names can be in any capitals.
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name.lowercased() == name }?.value
        }
        // "To" can be before the "?", in a "to=" pair, or both.
        let toAddresses = [components.path, value("to") ?? ""].filter { !$0.isEmpty }
        return ComposeDraft(
            to: toAddresses.joined(separator: ", "),
            cc: value("cc") ?? "",
            subject: value("subject") ?? "",
            body: value("body") ?? ""
        )
    }

    // MARK: - Helpers

    private static func addressList(_ addresses: [MailAddress]) -> String {
        addresses.map(\.formatted).joined(separator: ", ")
    }

    // Adds "RE:" or "FW:" in front of a subject, unless it's already there.
    private static func subject(_ original: String, withPrefix prefix: String, unlessStartsWith existing: [String]) -> String {
        let lowercased = original.lowercased()
        return existing.contains { lowercased.hasPrefix($0) } ? original : "\(prefix) \(original)"
    }

    // The quoted original underneath a reply or forward, Outlook style.
    private static func originalMessageBlock(_ message: MailMessage, body: String) -> String {
        var lines = [
            "", "",
            "-----Original Message-----",
            "From: \(message.sender.formatted)",
            "Sent: \(message.dateReceived.formatted(date: .complete, time: .shortened))",
            "To: \(addressList(message.toRecipients))",
        ]
        if !message.ccRecipients.isEmpty {
            lines.append("Cc: \(addressList(message.ccRecipients))")
        }
        lines += ["Subject: \(message.subject)", "", body]
        return lines.joined(separator: "\n")
    }
}
