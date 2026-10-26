// Everything that reads or changes mail on the server over IMAP lives here,
// using the SwiftMail library. Each function runs one job (list folders,
// fetch messages, delete one…) on the account's always-open connection.

import Foundation
import SwiftMail

enum IMAPService {
    // How many messages to download at a time (more load with "Show older messages").
    static let pageSize = 50

    // One open connection per account, created the first time it's needed.
    private static var connections: [UUID: AccountConnection] = [:]

    // Logs in and immediately out on a separate, temporary connection, to check
    // an account's settings work before they're saved. Pass `credential` to test
    // a password that isn't in the Keychain yet.
    static func testLogin(_ account: AccountSettings, credential: MailCredential? = nil) async throws {
        let server = try await connectAndLogIn(account, credential: credential)
        try? await server.logout()
    }

    // Returns the account's folders, Inbox first. Their unread counts start at 0:
    // asking for counts is a separate step (`fetchCounts`), because some servers
    // (Gmail, at about 1.4 seconds per folder) are slow to answer it.
    static func fetchFolders(for account: AccountSettings) async throws -> [MailFolder] {
        try await connection(for: account).run { server in
            var folders: [MailFolder] = []
            for mailbox in try await server.listMailboxes() where mailbox.isSelectable {
                folders.append(MailFolder(
                    accountID: account.id,
                    path: mailbox.name,
                    displayName: friendlyName(for: mailbox),
                    role: role(of: mailbox),
                    unreadCount: 0,
                    uidNext: nil
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

    // Asks the server how many unread messages a folder has, and the ID the next
    // new message will get (used to notice new mail), without opening the folder.
    static func fetchCounts(of folder: MailFolder, account: AccountSettings) async throws -> (unread: Int, uidNext: UInt32?) {
        try await connection(for: account).run { server in
            // Some servers give out-of-date counts for the folder that's currently open,
            // so close it first. (`try?` because there may be no folder open.)
            try? await server.unselectMailbox()
            // STATUS asks for a folder's counts without opening it.
            let status = try await server.mailboxStatus(folder.path)
            return (status.unseenCount ?? 0, status.uidNext?.value)
        }
    }

    // MARK: - Syncing the local copy (see MailSync)

    // How many messages' read/flag status to ask for per request.
    private static let flagBatchSize = 500

    // Asks the server which messages in a folder arrived since `startDate`, and
    // each one's read/flagged status: just numbers and flags, no headers.
    // The status is fetched in batches, each its own job, so other work can run in between.
    static func fetchSyncSnapshot(of folder: MailFolder, since startDate: Date, account: AccountSettings) async throws -> ServerFolderSnapshot {
        let (uidValidity, messageCount, uids) = try await connection(for: account).run { server in
            let selection = try await server.selectMailbox(folder.path)
            guard selection.messageCount > 0 else { return (selection.uidValidity.value, 0, [UInt32]()) }
            // SINCE uses the date each message arrived on the server.
            let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.since(startDate)])
            return (selection.uidValidity.value, selection.messageCount, (result.all?.toArray() ?? []).map(\.value))
        }
        var flags: [UInt32: MessageFlags] = [:]
        for start in stride(from: 0, to: uids.count, by: flagBatchSize) {
            let batch = Array(uids[start ..< min(start + flagBatchSize, uids.count)])
            let infos = try await connection(for: account).run { server in
                try await server.selectMailbox(folder.path)
                return try await server.fetchMessageInfosBulk(using: uidSet(batch), options: .uidFlagsOnly)
            }
            for info in infos {
                guard let uid = info.uid else { continue }
                flags[uid.value] = MessageFlags(isRead: info.flags.contains(.seen), isFlagged: info.flags.contains(.flagged))
            }
        }
        return ServerFolderSnapshot(uidValidity: uidValidity, messageCount: messageCount, flags: flags)
    }

    // Downloads the headers (sender, subject, date…) of the given messages.
    static func fetchHeaders(uids: [UInt32], in folder: MailFolder, account: AccountSettings) async throws -> [MailMessage] {
        guard !uids.isEmpty else { return [] }
        return try await connection(for: account).run { server in
            try await server.selectMailbox(folder.path)
            let infos = try await server.fetchMessageInfosBulk(using: uidSet(uids))
            return infos.compactMap { makeMailMessage(from: $0, account: account, folderPath: folder.path) }   // compactMap skips the nils
        }
    }

    // For "Show Older Messages": the next `limit` messages older than the offline
    // window (which aren't kept on this Mac), skipping the `alreadyShown` newest of them.
    static func fetchOlderMessages(in folder: MailFolder, before date: Date, skipping alreadyShown: Int, limit: Int,
                                   account: AccountSettings) async throws -> [MailMessage] {
        let uids = try await connection(for: account).run { server in
            try await server.selectMailbox(folder.path)
            let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.before(date)])
            // Higher UIDs are newer, so newest first.
            return (result.all?.toArray() ?? []).map(\.value).sorted(by: >).dropFirst(alreadyShown).prefix(limit)
        }
        return try await fetchHeaders(uids: Array(uids), in: folder, account: account)
    }

    // Asks the server to search a folder (sender, subject and body text) and
    // returns the newest matching messages.
    static func searchMessages(for account: AccountSettings, folderPath: String, query: String) async throws -> [MailMessage] {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            // IMAP's TEXT search looks in the headers and the body.
            let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [.text(query)])
            let matches = result.all?.toArray() ?? []
            // Higher UIDs are newer messages, so keep the highest ones.
            let newestMatches = matches.sorted { $0.value > $1.value }.prefix(pageSize)
            guard !newestMatches.isEmpty else { return [] }
            let infos = try await server.fetchMessageInfosBulk(using: UIDSet(Array(newestMatches)))
            return infos.compactMap { makeMailMessage(from: $0, account: account, folderPath: folderPath) }
        }
    }

    // Returns the messages that arrived since `firstNewUID` (used for new-mail alerts).
    static func fetchNewMessages(for account: AccountSettings, folderPath: String, firstNewUID: UInt32) async throws -> [MailMessage] {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            let infos = try await server.fetchMessageInfos(uidRange: UID(firstNewUID)...)
            // IMAP always returns at least the newest message for "from here on",
            // even if it's older than `firstNewUID`, so filter those out.
            return infos.compactMap { makeMailMessage(from: $0, account: account, folderPath: folderPath) }.filter { $0.uid >= firstNewUID }
        }
    }

    // Downloads a message's text, HTML and inline pictures, and marks it as read on the server.
    // Attachments are listed but not downloaded; each one downloads when you open it.
    static func fetchFullMessage(for account: AccountSettings, folderPath: String, uid: UInt32) async throws -> OpenMessage {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            guard let info = try await server.fetchMessageInfo(for: UID(uid)) else {
                return OpenMessage(plainText: "(This message could not be found on the server.)", html: nil, attachments: [])
            }
            // An email is made of numbered "parts" (text, HTML, each picture, each attachment).
            // First get the list of parts, then download only the ones needed to show the message.
            var parts = try await server.fetchStructure(UID(uid))
            let structure = Message(header: info, parts: parts)
            let neededSections = Set((structure.bodies + structure.cids).map(\.section))
            for index in parts.indices where neededSections.contains(parts[index].section) {
                parts[index].data = try await server.fetchPart(section: parts[index].section, of: UID(uid))
            }
            try await server.store(flags: [.seen], on: UIDSet(UID(uid)), operation: .add)
            return makeOpenMessage(from: Message(header: info, parts: parts), uid: uid, folderPath: folderPath, account: account)
        }
    }

    // Downloads one attachment (one part of a message) and undoes its email encoding.
    static func fetchAttachment(_ part: MessagePart, uid: UInt32, folderPath: String, account: AccountSettings) async throws -> Data {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            return try await server.fetchPart(section: part.section, of: UID(uid)).decoded(for: part)
        }
    }

    // Turns a flag such as "read" (\Seen) or "flagged" on or off for some messages.
    static func setFlag(_ flag: Flag, to isOn: Bool, uids: [UInt32], in folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            try await server.store(flags: [flag], on: uidSet(uids), operation: isOn ? .add : .remove)
        }
    }

    // Moves messages to another folder in the same account (also used by Delete to move them into Trash).
    static func moveMessages(uids: [UInt32], from folderPath: String, to destinationPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            try await server.move(messages: uidSet(uids), to: destinationPath)
        }
    }

    // Permanently erases messages (used when deleting from Trash).
    static func deletePermanently(uids: [UInt32], in folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            let messages = uidSet(uids)
            try await server.store(flags: [.deleted], on: messages, operation: .add)
            try await server.expunge(messages: messages)   // "expunge" = really remove deleted messages
        }
    }

    // Saves a copy of a sent email into a folder (for servers that don't do it themselves).
    static func saveCopy(of email: Email, to folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            _ = try await server.append(email: email, to: folderPath, flags: [.seen])
        }
    }

    // Saves an unfinished email into the Drafts folder and returns its new UID
    // (so a later save can replace it), if the server reports one.
    static func saveDraft(_ email: Email, to draftsPath: String, account: AccountSettings) async throws -> UInt32? {
        try await connection(for: account).run { server in
            let result = try await server.append(email: email, to: draftsPath, flags: [.draft, .seen])
            return result.firstUID?.value
        }
    }

    // Closes an account's connection, e.g. when the account is removed.
    static func closeConnection(for accountID: UUID) async {
        await connections.removeValue(forKey: accountID)?.close()
    }

    // MARK: - Connecting

    // Opens a new connection to the account's server and logs in, using
    // `credential` if given, or the one saved for the account otherwise.
    static func connectAndLogIn(_ account: AccountSettings, credential: MailCredential? = nil) async throws -> IMAPServer {
        let login: MailCredential
        if let credential {
            login = credential
        } else {
            login = try await MailCredential.forAccount(account)
        }
        let server = IMAPServer(host: account.imapHost, port: account.imapPort)
        try await server.connect()
        do {
            switch login {
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

    // SwiftMail's set-of-message-IDs type, built from our plain numbers.
    private static func uidSet(_ uids: [UInt32]) -> UIDSet {
        UIDSet(uids.map { UID($0) })
    }

    private static func connection(for account: AccountSettings) -> AccountConnection {
        if let existing = connections[account.id] { return existing }
        let connection = AccountConnection(account: account)
        connections[account.id] = connection
        return connection
    }

    // MARK: - Converting SwiftMail's types into ours

    // Returns nil if the server didn't give the message a UID.
    // `account` and `folderPath` say which folder the message came from.
    private static func makeMailMessage(from info: MessageInfo, account: AccountSettings, folderPath: String) -> MailMessage? {
        guard let uid = info.uid else { return nil }
        // Turns SwiftMail's address entries into our MailAddress type.
        func addresses(_ entries: [AddressListEntry]) -> [MailAddress] {
            entries.mailboxes.map { MailAddress(name: $0.name, address: $0.address) }
        }
        return MailMessage(
            uid: uid.value,
            folderID: MailFolder.id(accountID: account.id, path: folderPath),
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

    // `uid`, `folderPath` and `account` say where the message lives, so each
    // attachment knows where to download itself from later.
    private static func makeOpenMessage(from message: Message, uid: UInt32, folderPath: String, account: AccountSettings) -> OpenMessage {
        let attachments = message.attachments.map { part in
            // The server reports the size as sent, and attachments are usually sent
            // as base64 text, which is about 4/3 the size of the real file.
            let isBase64 = part.encoding?.lowercased() == "base64"
            return MailAttachment(
                filename: part.suggestedFilename,
                mimeType: part.contentType,
                approximateSize: part.size.map { isBase64 ? $0 * 3 / 4 : $0 },
                download: { try await fetchAttachment(part, uid: uid, folderPath: folderPath, account: account) }
            )
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
