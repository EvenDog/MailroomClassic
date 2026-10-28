// Everything that reads or changes mail on the server over IMAP lives here,
// using the SwiftMail library. Each function runs one job (list folders,
// fetch messages, delete one…) on one of the account's always-open connections:
// the main one for most work, a "reading" one just for opening messages (so that
// never waits behind background work like syncing), and a "downloading" one for
// fetching message contents ahead of time, for offline reading.

import Foundation
import SwiftMail

// A message's contents as downloaded: the text and HTML to show (with the
// pictures inside the email already filled in), and the list of its attachments
// (not their contents, which download when you open one). MailCache saves it, so
// opening the message again doesn't need the server.
nonisolated struct MessageBody: Codable, Sendable {
    var plainText: String
    var html: String?
    var attachmentParts: [MessagePart]
}

enum IMAPService {
    // How many messages to download at a time (more load with "Show older messages").
    static let pageSize = 50

    // One open connection per account, created the first time it's needed.
    private static var connections: [UUID: AccountConnection] = [:]
    // The extra connections, each with its own job, so none waits behind another's work.
    private enum SpareConnection {
        case reading       // opening messages and their attachments
        case downloading   // fetching message contents ahead of time (see MailStore.downloadForOffline)
    }
    private static var spareConnections: [SpareConnection: [UUID: AccountConnection]] = [:]

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
            let mailboxes = try await server.listMailboxes()
            // If the server labels any of its special folders (Gmail, MXroute and Office 365 do),
            // trust those labels rather than guessing from names, so a folder you made
            // called "Drafts" isn't mistaken for the real one.
            let serverLabelsFolders = mailboxes.contains { !$0.attributes.isDisjoint(with: specialUseAttributes) }
            for mailbox in mailboxes where mailbox.isSelectable {
                folders.append(MailFolder(
                    accountID: account.id,
                    path: mailbox.name,
                    displayName: friendlyName(for: mailbox),
                    role: role(of: mailbox, guessFromName: !serverLabelsFolders),
                    unreadCount: 0,
                    hierarchyDelimiter: mailbox.hierarchyDelimiter,
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
            // STATUS asks for a folder's counts without opening it.
            // (This used to close the open folder first, in case a server gave stale
            // counts for it, but Gmail sometimes took over SwiftMail's 5-second limit
            // to do that, which dropped the connection.)
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
                flags[uid.value] = MessageFlags(isRead: info.flags.contains(.seen), isFlagged: info.flags.contains(.flagged),
                                                categories: MailCategory.from(info.flags))
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

    // Downloads what's needed to show a message: its text, its HTML version and the
    // pictures inside it (attachments wait until you open them). Each request costs
    // Gmail about a second, so this uses as few as it can: open the folder (skipped
    // if it's already open), get the list of parts, then all the needed parts in one
    // go. It doesn't mark the message as read; see `markAsRead`.
    // Returns nil if the message isn't on the server any more.
    static func fetchBody(for account: AccountSettings, folderPath: String, uid: UInt32) async throws -> MessageBody? {
        try await onSpareConnection(.reading, of: account, folderPath: folderPath) { server in
            var parts = try await server.fetchStructure(UID(uid))
            guard !parts.isEmpty else { return nil }
            // SwiftMail's Message needs a header, but only the parts are used to show the
            // message (the sender, subject… are already saved on this Mac), so a stand-in will do.
            let header = MessageInfo(sequenceNumber: SequenceNumber(1), uid: UID(uid))
            let structure = Message(header: header, parts: parts)
            let neededSections = Set((structure.bodies + structure.cids).map(\.section))
            let requests = parts.filter { neededSections.contains($0.section) }.map { (uid: UID(uid), section: $0.section) }
            if !requests.isEmpty {
                // "Pipelined": all the requests are sent at once instead of waiting for each answer.
                let downloaded = try await server.fetchPartsPipelined(parts: requests)[UID(uid)] ?? []
                for (section, data) in downloaded {
                    if let index = parts.firstIndex(where: { $0.section == section }) { parts[index].data = data }
                }
            }
            return makeBody(from: Message(header: header, parts: parts))
        }
    }

    // Downloads the contents of several messages in one folder at once, for offline
    // reading: one request for all their lists of parts, then one burst for every
    // needed part (text, HTML, pictures inside the email). Pass at most 50 or so.
    // Messages no longer on the server are left out of the result.
    static func fetchBodies(uids: [UInt32], in folderPath: String, account: AccountSettings) async throws -> [UInt32: MessageBody] {
        guard !uids.isEmpty else { return [:] }
        return try await onSpareConnection(.downloading, of: account, folderPath: folderPath) { server in
            let infos = try await server.fetchMessageInfosBulk(using: uidSet(uids), options: [.bodyStructure])
            var requests: [(uid: UID, section: Section)] = []
            for info in infos {
                guard let uid = info.uid else { continue }
                let structure = Message(header: info, parts: info.parts)
                requests += (structure.bodies + structure.cids).map { (uid: uid, section: $0.section) }
            }
            let downloaded = requests.isEmpty ? [:] : try await server.fetchPartsPipelined(parts: requests)

            var bodies: [UInt32: MessageBody] = [:]
            for info in infos {
                guard let uid = info.uid else { continue }
                var parts = info.parts
                for (section, data) in downloaded[uid] ?? [] {
                    if let index = parts.firstIndex(where: { $0.section == section }) { parts[index].data = data }
                }
                bodies[uid.value] = makeBody(from: Message(header: info, parts: parts))
            }
            return bodies
        }
    }

    // Marks one message as read on the server (after it's been shown).
    static func markAsRead(uid: UInt32, in folderPath: String, account: AccountSettings) async throws {
        try await onSpareConnection(.reading, of: account, folderPath: folderPath) { server in
            try await server.store(flags: [.seen], on: UIDSet(UID(uid)), operation: .add)
        }
    }

    // How to unsubscribe from the mailing list a message came from, or nil if it
    // doesn't say. Asks for just the two List-Unsubscribe header lines (a few
    // hundred bytes), not the whole message. `options: []` skips everything else.
    static func fetchUnsubscribeMethod(uid: UInt32, in folderPath: String, account: AccountSettings) async throws -> UnsubscribeMethod? {
        try await onSpareConnection(.reading, of: account, folderPath: folderPath) { server in
            let info = try await server.fetchMessageInfo(for: UID(uid), options: [], headerFields: UnsubscribeMethod.headerNames)
            // SwiftMail stores header lines under lowercase names.
            guard let listUnsubscribe = info?.additionalFields?["list-unsubscribe"] else { return nil }
            return UnsubscribeMethod(listUnsubscribe: listUnsubscribe,
                                     listUnsubscribePost: info?.additionalFields?["list-unsubscribe-post"])
        }
    }

    // Downloads one attachment (one part of a message) and undoes its email encoding.
    static func fetchAttachment(_ part: MessagePart, uid: UInt32, folderPath: String, account: AccountSettings) async throws -> Data {
        try await onSpareConnection(.reading, of: account, folderPath: folderPath) { server in
            try await server.fetchPart(section: part.section, of: UID(uid)).decoded(for: part)
        }
    }

    // Turns a flag such as "read" (\Seen) or "flagged" on or off for some messages.
    static func setFlag(_ flag: Flag, to isOn: Bool, uids: [UInt32], in folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            try await server.store(flags: [flag], on: uidSet(uids), operation: isOn ? .add : .remove)
        }
    }

    // Adds color categories to messages (or, with `isOn: false`, takes them off),
    // as keywords on the server (see Categories). One request for all of them.
    static func setCategories(_ categories: [MailCategory], to isOn: Bool, uids: [UInt32], in folderPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            try await server.store(flags: categories.map { .custom($0.keyword) }, on: uidSet(uids), operation: isOn ? .add : .remove)
        }
    }

    // Moves messages to another folder in the same account (also used by Delete to move them into Trash).
    // Returns the IDs the messages were given in the destination folder (Undo needs them
    // to move them back), or nil if the server didn't say. Servers with the "UIDPLUS"
    // feature (Gmail, Office 365 and MXroute all have it) report them.
    @discardableResult
    static func moveMessages(uids: [UInt32], from folderPath: String, to destinationPath: String, account: AccountSettings) async throws -> [UInt32]? {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            // `CopyUID.mapping` pairs each message's old ID with its new one.
            let copyUID = try await server.move(messages: uidSet(uids), to: destinationPath)
            return copyUID?.mapping.map(\.destination.value)
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
        // No retry: if the first try saved it but the reply was slow, a retry would save a second copy.
        try await connection(for: account).run(retryOnTimeout: false) { server in
            _ = try await server.append(email: email, to: folderPath, flags: [.seen])
        }
    }

    // Saves an unfinished email into the Drafts folder and returns its new UID
    // (so a later save can replace it), if the server reports one.
    static func saveDraft(_ email: Email, to draftsPath: String, account: AccountSettings) async throws -> UInt32? {
        try await connection(for: account).run(retryOnTimeout: false) { server in   // no retry, as in saveCopy
            let result = try await server.append(email: email, to: draftsPath, flags: [.draft, .seen])
            return result.firstUID?.value
        }
    }

    // MARK: - Copying between accounts

    // Downloads one message exactly as it's stored on the server: every header,
    // the text and every attachment, as one block of text (the "raw" message).
    // Used to copy a message into another account. Doesn't mark it as read.
    static func fetchRawMessage(uid: UInt32, in folderPath: String, account: AccountSettings) async throws -> Data {
        try await connection(for: account).run { server in
            try await server.selectMailbox(folderPath)
            return try await server.fetchRawMessage(identifier: UID(uid))
        }
    }

    // Uploads a raw message (from fetchRawMessage) into a folder, with its
    // read/flagged status and original date, so it looks the same as before.
    static func uploadRawMessage(_ rawMessage: String, to folderPath: String, flags: [Flag], date: Date?,
                                 account: AccountSettings) async throws {
        // No retry: if the first try saved it but the reply was slow, a retry would save a second copy.
        try await connection(for: account).run(retryOnTimeout: false) { server in
            _ = try await server.append(rawMessage: rawMessage, to: folderPath, flags: flags, internalDate: date)
        }
    }

    // MARK: - Managing folders
    // No retries for these: if the first try worked but its reply was slow, a retry
    // would fail ("already exists" / "doesn't exist") and wrongly report an error.

    // Creates a folder. `path` is its full server name (see MailFolder.childPath);
    // SwiftMail adds the server's prefix (like MXroute's "INBOX.") if it's missing.
    static func createFolder(path: String, account: AccountSettings) async throws {
        try await connection(for: account).run(retryOnTimeout: false) { server in
            try await server.createMailbox(path)
        }
    }

    static func renameFolder(from oldPath: String, to newPath: String, account: AccountSettings) async throws {
        try await connection(for: account).run(retryOnTimeout: false) { server in
            try await server.renameMailbox(oldPath, to: newPath)
        }
    }

    // Deletes a folder and the messages in it. (Gmail removes the label; the messages stay in All Mail.)
    static func deleteFolder(path: String, account: AccountSettings) async throws {
        try await connection(for: account).run(retryOnTimeout: false) { server in
            try await server.deleteMailbox(path)
        }
    }

    // The UIDs of every message in a folder, or just the unread ones
    // (for Empty Trash and Mark All as Read).
    static func fetchAllUIDs(in folderPath: String, onlyUnread: Bool, account: AccountSettings) async throws -> [UInt32] {
        try await connection(for: account).run { server in
            let selection = try await server.selectMailbox(folderPath)
            guard selection.messageCount > 0 else { return [] }
            let result: ExtendedSearchResult<UID> = try await server.extendedSearch(criteria: [onlyUnread ? .unseen : .all])
            return (result.all?.toArray() ?? []).map(\.value)
        }
    }

    // Closes an account's connection, e.g. when the account is removed.
    static func closeConnection(for accountID: UUID) async {
        await connections.removeValue(forKey: accountID)?.close()
        for kind in [SpareConnection.reading, .downloading] {
            await spareConnections[kind]?.removeValue(forKey: accountID)?.close()
        }
    }

    // MARK: - Connecting

    // Closes an account's "downloading" connection when a download run is over,
    // so it doesn't sit open (and get checked) until the next one.
    static func closeDownloadingConnection(for accountID: UUID) async {
        await spareConnections[.downloading]?.removeValue(forKey: accountID)?.close()
    }

    // Opens a new connection to the account's server and logs in, using
    // `credential` if given, or the one saved for the account otherwise.
    static func connectAndLogIn(_ account: AccountSettings, credential: MailCredential? = nil) async throws -> IMAPServer {
        let login: MailCredential
        if let credential {
            login = credential
        } else {
            login = try await MailCredential.forAccount(account)
        }
        // SwiftMail can't guess the security for Proton Mail Bridge's port (1143), so say it: STARTTLS,
        // which starts unencrypted and switches encryption on straight away.
        let security: MailTransportSecurity = account.provider == .proton ? .startTLS : .automatic
        let server = IMAPServer(host: account.imapHost, port: account.imapPort, transportSecurity: security)
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

    // Runs `job` on one of the account's extra connections with `folderPath` open.
    // Opening the folder is skipped if it's already open there. If the job then
    // fails, the server may have quietly reconnected (which closes the folder),
    // so this opens the folder for real and tries once more.
    private static func onSpareConnection<Result: Sendable>(
        _ kind: SpareConnection,
        of account: AccountSettings,
        folderPath: String,
        _ job: @escaping (IMAPServer) async throws -> Result
    ) async throws -> Result {
        let reader: AccountConnection
        if let existing = spareConnections[kind]?[account.id] {
            reader = existing
        } else {
            reader = AccountConnection(account: account)
            spareConnections[kind, default: [:]][account.id] = reader
        }
        return try await reader.run { server in
            let openedFolder = try await reader.select(folderPath, on: server)
            do {
                return try await job(server)
            } catch let error where !openedFolder && !(error is CancellationError) {
                reader.forgetSelectedFolder()
                try await reader.select(folderPath, on: server)
                return try await job(server)
            }
        }
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
            isFlagged: info.flags.contains(.flagged),
            categories: MailCategory.from(info.flags)
        )
    }

    // `uid`, `folderPath` and `account` say where the message lives, so each
    // attachment knows where to download itself from later.
    // Turns downloaded parts into a MessageBody: fills the pictures into the HTML,
    // and makes a plain-text version if the email only came as HTML.
    private static func makeBody(from message: Message) -> MessageBody {
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
        // Keep only each attachment's description, not any downloaded contents (a picture
        // can count as an attachment too), so the saved copy stays small.
        let attachmentParts = message.attachments.map { part in
            var description = part
            description.data = nil
            return description
        }
        return MessageBody(plainText: plainText, html: html, attachmentParts: attachmentParts)
    }

    // What the reading pane shows for a MessageBody (just downloaded, or saved on this
    // Mac). Each attachment gets a `download` that fetches it from the server when opened.
    static func openMessage(from body: MessageBody, uid: UInt32, folderPath: String, account: AccountSettings) -> OpenMessage {
        let attachments = body.attachmentParts.map { part in
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
        return OpenMessage(plainText: body.plainText, html: body.html, attachments: attachments)
    }

    // Uses the server's "special-use" labels (\Sent, \Trash…) when present,
    // otherwise guesses from the folder's name.
    // The "special-use" labels a server can put on its folders.
    private static let specialUseAttributes: Mailbox.Info.Attributes = [.drafts, .sent, .trash, .junk, .archive, .all]

    // `guessFromName` is false when the server labels its special folders, so
    // only those labels count (the Inbox is always called INBOX).
    private static func role(of mailbox: Mailbox.Info, guessFromName: Bool) -> FolderRole {
        let attributes = mailbox.attributes
        if attributes.contains(.inbox) || mailbox.name.uppercased() == "INBOX" { return .inbox }
        if attributes.contains(.drafts) { return .drafts }
        if attributes.contains(.sent) { return .sent }
        if attributes.contains(.trash) { return .trash }
        if attributes.contains(.junk) { return .junk }
        if attributes.contains(.archive) { return .archive }
        if attributes.contains(.all) { return .allMail }
        return guessFromName ? FolderRole(name: friendlyName(for: mailbox)) : .other
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
