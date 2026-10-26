// Everything that reads or changes mail on the server over IMAP lives here,
// using the SwiftMail library. Each function runs one job (list folders,
// fetch messages, delete one…) on the account's always-open connection.

import Foundation
import SwiftMail

enum IMAPService {
    // How many of the newest messages to download per folder.
    static let messagesPerFolder = 50

    // One open connection per account, created the first time it's needed.
    private static var connections: [UUID: AccountConnection] = [:]

    // Logs in and immediately out on a separate, temporary connection, to check
    // a new account's settings work before it's saved.
    static func testLogin(_ account: AccountSettings) async throws {
        let server = try await connectAndLogIn(account)
        try? await server.logout()
    }

    // Returns the account's folders, Inbox first, each with its unread count.
    static func fetchFolders(for account: AccountSettings) async throws -> [MailFolder] {
        try await connection(for: account).run { server in
            var folders: [MailFolder] = []
            for mailbox in try await server.listMailboxes() where mailbox.isSelectable {
                // STATUS asks the server for counts without opening the folder.
                let status = try? await server.mailboxStatus(mailbox.name)
                folders.append(MailFolder(
                    accountID: account.id,
                    path: mailbox.name,
                    displayName: friendlyName(for: mailbox),
                    role: role(of: mailbox),
                    unreadCount: status?.unseenCount ?? 0
                ))
            }
            // Sort like classic Outlook: Inbox, Drafts, Sent, Deleted, Junk, then the rest A–Z.
            return folders.sorted {
                $0.role.sortRank != $1.role.sortRank
                    ? $0.role.sortRank < $1.role.sortRank
                    : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }

    // Returns summaries (sender, subject, date, read/unread) of the newest messages in a folder.
    static func fetchLatestMessages(for account: AccountSettings, folderPath: String) async throws -> [MailMessage] {
        try await connection(for: account).run { server in
            let selection = try await server.selectMailbox(folderPath)
            guard let newest = selection.latest(messagesPerFolder) else { return [] }   // empty folder
            let infos = try await server.fetchMessageInfosBulk(using: newest)
            return infos.compactMap { makeMailMessage(from: $0) }   // compactMap skips the nils
        }
    }

    // Downloads one whole message (text, HTML and attachments) and marks it as read on the server.
    static func fetchFullMessage(for account: AccountSettings, folderPath: String, uid: UInt32) async throws -> OpenMessage {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            guard let info = try await server.fetchMessageInfo(for: UID(uid)) else {
                return OpenMessage(plainText: "(This message could not be found on the server.)", html: nil, attachments: [])
            }
            let message = try await server.fetchMessage(from: info)
            try await server.store(flags: [.seen], on: UIDSet(UID(uid)), operation: .add)
            return makeOpenMessage(from: message)
        }
    }

    // Turns a flag such as "read" (\Seen) or "flagged" on or off for one message.
    static func setFlag(_ flag: Flag, to isOn: Bool, uid: UInt32, in folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            try await server.store(flags: [flag], on: UIDSet(UID(uid)), operation: isOn ? .add : .remove)
        }
    }

    // Moves a message to another folder (used by Delete to move it into Trash).
    static func moveMessage(uid: UInt32, from folderPath: String, to destinationPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            try await server.move(messages: UIDSet(UID(uid)), to: destinationPath)
        }
    }

    // Permanently erases a message (used when deleting from Trash).
    static func deletePermanently(uid: UInt32, in folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            let thisMessage = UIDSet(UID(uid))
            try await server.store(flags: [.deleted], on: thisMessage, operation: .add)
            try await server.expunge(messages: thisMessage)   // "expunge" = really remove deleted messages
        }
    }

    // Saves a copy of a sent email into a folder (for servers that don't do it themselves).
    static func saveCopy(of email: Email, to folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            _ = try await server.append(email: email, to: folderPath, flags: [.seen])
        }
    }

    // Closes an account's connection, e.g. when the account is removed.
    static func closeConnection(for accountID: UUID) async {
        await connections.removeValue(forKey: accountID)?.close()
    }

    // MARK: - Connecting

    // Opens a new connection to the account's server and logs in.
    static func connectAndLogIn(_ account: AccountSettings) async throws -> IMAPServer {
        let credential = try await MailCredential.forAccount(account)
        let server = IMAPServer(host: account.imapHost, port: account.imapPort)
        try await server.connect()
        do {
            switch credential {
            case .password(let password):
                try await server.login(username: account.emailAddress, password: password)
            case .accessToken(let token):
                try await server.authenticateXOAUTH2(email: account.emailAddress, accessToken: token)
            }
            return server
        } catch {
            try? await server.disconnect()
            throw error
        }
    }

    private static func connection(for account: AccountSettings) -> AccountConnection {
        if let existing = connections[account.id] { return existing }
        let connection = AccountConnection(account: account)
        connections[account.id] = connection
        return connection
    }

    // MARK: - Converting SwiftMail's types into ours

    // Returns nil if the server didn't give the message a UID.
    private static func makeMailMessage(from info: MessageInfo) -> MailMessage? {
        guard let uid = info.uid else { return nil }
        // Turns SwiftMail's address entries into our MailAddress type.
        func addresses(_ entries: [AddressListEntry]) -> [MailAddress] {
            entries.mailboxes.map { MailAddress(name: $0.name, address: $0.address) }
        }
        return MailMessage(
            uid: uid.value,
            sender: addresses(info.fromAddresses).first ?? MailAddress(name: "(Unknown sender)", address: ""),
            replyTo: addresses(info.replyToAddresses),
            toRecipients: addresses(info.toAddresses),
            ccRecipients: addresses(info.ccAddresses),
            subject: info.subject ?? "(No subject)",
            dateReceived: info.date ?? info.internalDate ?? .distantPast,
            messageID: info.messageId?.description,
            references: (info.references ?? []).map(\.description),   // `\.description` = `{ $0.description }`
            // The message's structure (which parts it has) arrives with the summary,
            // so we can show a paperclip before downloading anything.
            hasAttachments: !Message(header: info, parts: info.parts).attachments.isEmpty,
            isRead: info.flags.contains(.seen),
            isFlagged: info.flags.contains(.flagged)
        )
    }

    private static func makeOpenMessage(from message: Message) -> OpenMessage {
        let attachments = message.attachments.compactMap { part -> MailAttachment? in
            // `decodedData()` undoes the email encoding (usually base64) to get the real file.
            guard let data = part.decodedData() else { return nil }
            return MailAttachment(filename: part.suggestedFilename, mimeType: part.contentType, data: data)
        }

        var html = message.htmlBody
        // Pictures inside an email (logos, signatures) are referred to as "cid:something".
        // Swap each reference for the picture itself, written out as a data: URL.
        for part in message.cids {
            guard let contentID = part.contentId, let data = part.decodedData() else { continue }
            let bareID = contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            html = html?.replacingOccurrences(
                of: "cid:\(bareID)",
                with: "data:\(part.contentType);base64,\(data.base64EncodedString())"
            )
        }

        let plainText: String
        if let text = message.textBody, !text.isEmpty {
            plainText = text
        } else if let html {
            plainText = stripHTML(html)
        } else {
            plainText = "(This message has no text.)"
        }
        return OpenMessage(plainText: plainText, html: html, attachments: attachments)
    }

    // Uses the server's "special-use" labels (\Sent, \Trash…) when present,
    // otherwise guesses from the folder's name.
    private static func role(of mailbox: Mailbox.Info) -> FolderRole {
        let attributes = mailbox.attributes
        if attributes.contains(.inbox) { return .inbox }
        if attributes.contains(.drafts) { return .drafts }
        if attributes.contains(.sent) { return .sent }
        if attributes.contains(.trash) { return .trash }
        if attributes.contains(.junk) { return .junk }
        if attributes.contains(.archive) { return .archive }
        return FolderRole(name: friendlyName(for: mailbox))
    }

    // Turns "INBOX" into "Inbox", "INBOX.Sent" into "Sent", and "[Gmail]/Sent Mail" into "Sent Mail".
    private static func friendlyName(for mailbox: Mailbox.Info) -> String {
        if mailbox.name.uppercased() == "INBOX" { return "Inbox" }
        let delimiter = mailbox.hierarchyDelimiter ?? "/"
        for prefix in ["INBOX" + delimiter, "[Gmail]" + delimiter, "[Google Mail]" + delimiter]
        where mailbox.name.uppercased().hasPrefix(prefix.uppercased()) {
            return String(mailbox.name.dropFirst(prefix.count))
        }
        return mailbox.name
    }

    // A rough HTML-to-text conversion, used for quoting HTML emails in replies.
    // Each `replacingOccurrences(..., options: .regularExpression)` finds text
    // matching a pattern and replaces it.
    private static func stripHTML(_ html: String) -> String {
        var text = html
            .replacingOccurrences(of: "(?is)<(style|script|head)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</tr>|</h[1-6]>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // Collapse runs of 3+ blank lines left behind by removed tags.
        return text
            .replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
