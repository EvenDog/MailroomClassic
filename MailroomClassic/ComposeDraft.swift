// The contents of a compose window (From, To, Cc, Subject, body), plus helpers
// that pre-fill one for Reply, Reply All and Forward, quoting the original
// message the way classic Outlook did.

import Foundation

// `Codable` and `Hashable` are required so SwiftUI can hand a draft to a new window.
struct ComposeDraft: Codable, Hashable {
    var id = UUID()            // makes every draft unique, so each opens its own window
    var accountID: UUID?       // which account to send from
    var to = ""
    var cc = ""
    var subject = ""
    var body = ""
    var inReplyTo: String?     // Message-ID of the email being replied to (keeps conversations threaded)
    var references: [String] = []
    var attachmentURLs: [URL] = []   // files on disk to attach
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
