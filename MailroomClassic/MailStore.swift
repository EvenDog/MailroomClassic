// The app's shared state: the list of accounts, their folders, the messages
// in the folder you're looking at, and the body of the open message. Views
// read from it, and call its functions to add accounts, load, send or change mail.

import Foundation
import Observation
import SwiftMail

// `@Observable` makes SwiftUI watch this object: whenever one of its
// properties changes, any view that reads that property redraws itself.
@Observable
final class MailStore {
    private(set) var accounts: [AccountSettings] = AccountStorage.loadAccounts()
    private(set) var foldersByAccount: [UUID: [MailFolder]] = [:] {
        // `didSet` runs after every change: keep the Dock badge's unread count up to date.
        didSet { NewMailNotifier.updateDockBadge(unreadCount: unreadInboxCount) }
    }
    private(set) var messages: [MailMessage] = []
    private(set) var openMessage: OpenMessage?   // the full contents of the message in the reading pane
    private(set) var statusText = "Ready"
    private(set) var isShowingSearchResults = false

    // Which folder (or All Inboxes) `messages` came from, how many we asked for
    // from each folder, and how many messages those folders hold in total.
    private var shownFolderID: String?
    private var messageLimit = IMAPService.pageSize
    private var totalMessageCount = 0

    // Attachments of the open message that are already downloaded, so opening one
    // twice doesn't download it twice. Emptied when another message is opened.
    private var downloadedAttachments: [MailAttachment.ID: Data] = [:]

    // True when the folder has messages older than the ones on screen.
    var hasOlderMessages: Bool {
        !isShowingSearchResults && messages.count < totalMessageCount
    }

    // Every folder from every account, in one list.
    var allFolders: [MailFolder] {
        accounts.flatMap { foldersByAccount[$0.id] ?? [] }
    }

    // Unread messages across every account's Inbox (shown on the Dock icon).
    var unreadInboxCount: Int {
        allFolders.filter { $0.role == .inbox }.reduce(0) { $0 + $1.unreadCount }   // reduce = add them all up
    }

    // MARK: - Accounts

    // Saves the account's secret (password or Microsoft refresh token), checks
    // that logging in works, then adds the account. Throws if the login fails,
    // so the Settings window can show the error; nothing is kept in that case.
    func addAccount(_ account: AccountSettings, secret: String) async throws {
        try AccountStorage.saveSecret(secret, for: account.id)
        do {
            try await IMAPService.testLogin(account)
        } catch {
            AccountStorage.deleteSecret(for: account.id)
            MicrosoftOAuth.forgetCachedToken(for: account.id)
            throw error
        }
        accounts.append(account)
        AccountStorage.saveAccounts(accounts)
        await refreshFolders(for: account)
    }

    // Saves changes to an existing account after checking the new settings can
    // log in. `newSecret` is a new password (or Microsoft token), or nil to keep the old one.
    // Throws if the login fails; the account is left unchanged in that case.
    func updateAccount(_ updated: AccountSettings, newSecret: String?) async throws {
        var testCredential: MailCredential?
        if let newSecret, updated.provider != .office365 {
            testCredential = .password(newSecret)
        }
        try await IMAPService.testLogin(updated, credential: testCredential)
        if let newSecret {
            try AccountStorage.saveSecret(newSecret, for: updated.id)
        }
        guard let index = accounts.firstIndex(where: { $0.id == updated.id }) else { return }
        accounts[index] = updated
        AccountStorage.saveAccounts(accounts)
        // The open connection still uses the old settings, so start a new one.
        await IMAPService.closeConnection(for: updated.id)
        await refreshFolders(for: updated)
    }

    func removeAccount(_ account: AccountSettings) {
        Task { await IMAPService.closeConnection(for: account.id) }
        AccountStorage.deleteSecret(for: account.id)
        MicrosoftOAuth.forgetCachedToken(for: account.id)
        accounts.removeAll { $0.id == account.id }
        foldersByAccount[account.id] = nil
        AccountStorage.saveAccounts(accounts)
    }

    // MARK: - Reading mail

    // Reloads every account's folder list and unread counts ("Send/Receive").
    func refreshAllFolders() async {
        for account in accounts {
            await refreshFolders(for: account)
        }
    }

    // Reloads one account's folders, and announces any new mail in its Inbox.
    func refreshFolders(for account: AccountSettings) async {
        await reportingErrors("Checking \(account.displayName)…", server: account.imapHost) {
            let previousFolders = foldersByAccount[account.id] ?? []
            let folders = try await IMAPService.fetchFolders(for: account)
            foldersByAccount[account.id] = folders

            // If an Inbox's "next message ID" went up since last time, new mail arrived.
            // (On the first check there's nothing to compare with, so no alerts.)
            for inbox in folders where inbox.role == .inbox {
                guard let previous = previousFolders.first(where: { $0.id == inbox.id }),
                      let oldNext = previous.uidNext, let newNext = inbox.uidNext, newNext > oldNext else { continue }
                // `try?`: if fetching the details fails, skip the alert rather than failing the check.
                let arrivals = (try? await IMAPService.fetchNewMessages(for: account, folderPath: inbox.path, firstNewUID: oldNext)) ?? []
                NewMailNotifier.announce(arrivals.filter { !$0.isRead }, account: account)
            }
        }
    }

    // Shows the newest messages in a folder (the first page of them).
    func loadMessages(in folder: MailFolder) async {
        await loadMessages(from: [folder], viewID: folder.id)
    }

    // Shows the newest messages from one or more folders, mixed together newest
    // first. Several folders means All Inboxes. `viewID` is the sidebar row being
    // shown (a folder's ID, or MailFolder.allInboxesID).
    func loadMessages(from folders: [MailFolder], viewID: String) async {
        if shownFolderID != viewID {
            messages = []
            messageLimit = IMAPService.pageSize
        }
        shownFolderID = viewID
        isShowingSearchResults = false
        let name = folders.count == 1 ? folders[0].displayName : "All Inboxes"
        await fetchMessages(from: folders, viewID: viewID, activity: "Loading \(name)…")
    }

    // "Show older messages": loads another page further back in time.
    func loadOlderMessages(from folders: [MailFolder], viewID: String) async {
        messageLimit += IMAPService.pageSize
        await fetchMessages(from: folders, viewID: viewID, activity: "Loading older messages…")
    }

    // Replaces the message list with the server's search results for `query`.
    func search(_ query: String, in folders: [MailFolder], viewID: String) async {
        let name = folders.count == 1 ? folders[0].displayName : "All Inboxes"
        let results = await collectMessages(from: folders, activity: "Searching \(name)…") { account, folder in
            try await IMAPService.searchMessages(for: account, folderPath: folder.path, query: query)
        }
        guard let results, shownFolderID == viewID else { return }   // failed, or you switched folders meanwhile
        messages = results.sorted { $0.dateReceived > $1.dateReceived }
        isShowingSearchResults = true
        if statusText == "Ready" {   // don't hide an error about one of the accounts
            statusText = messages.count == 1 ? "1 message found" : "\(messages.count) messages found"
        }
    }

    private func fetchMessages(from folders: [MailFolder], viewID: String, activity: String) async {
        var totalCount = 0
        let limit = messageLimit
        let fetched = await collectMessages(from: folders, activity: activity) { account, folder in
            let page = try await IMAPService.fetchLatestMessages(for: account, folderPath: folder.path, limit: limit)
            totalCount += page.totalCount
            return page.messages
        }
        // If you clicked another folder while this was loading, throw this result away.
        guard let fetched, !Task.isCancelled, shownFolderID == viewID else { return }
        // With several folders, keep only the newest `limit` of them all.
        messages = Array(fetched.sorted { $0.dateReceived > $1.dateReceived }.prefix(limit))
        totalMessageCount = totalCount
    }

    // Runs `fetch` on each folder in turn and returns everything it found, while
    // showing `activity` in the status bar. If some accounts fail, the others'
    // messages are still returned, and the status bar says which failed.
    // Returns nil if every folder failed (or the work was cancelled).
    private func collectMessages(
        from folders: [MailFolder],
        activity: String,
        fetch: (AccountSettings, MailFolder) async throws -> [MailMessage]
    ) async -> [MailMessage]? {
        statusText = activity
        var found: [MailMessage] = []
        var problems: [String] = []
        for folder in folders {
            guard let account = account(for: folder) else { continue }
            do {
                found += try await fetch(account, folder)
            } catch is CancellationError {
                return nil   // you clicked something else; not a real error
            } catch {
                let problem = FriendlyError.message(for: error, server: account.imapHost)
                problems.append(folders.count == 1 ? problem : "\(account.displayName): \(problem)")
            }
        }
        statusText = problems.isEmpty ? "Ready" : "Error: " + problems.joined(separator: " · ")
        return problems.count == folders.count && !folders.isEmpty ? nil : found
    }

    // The folder a message is in, e.g. to know which account to ask about it.
    func folder(of message: MailMessage) -> MailFolder? {
        allFolders.first { $0.id == message.folderID }
    }

    // Downloads a whole message (text, HTML, attachments) and marks it as read.
    func open(_ message: MailMessage, in folder: MailFolder) async {
        openMessage = nil
        downloadedAttachments = [:]
        guard let account = account(for: folder) else { return }
        await reportingErrors("Opening message…", server: account.imapHost) {
            let contents = try await IMAPService.fetchFullMessage(for: account, folderPath: folder.path, uid: message.uid)
            guard !Task.isCancelled else { return }
            openMessage = contents
            // Remember the sender for To/Cc suggestions (but not junk mail senders).
            if folder.role != .junk {
                RecentAddresses.remember([message.sender])
            }
            if !message.isRead {
                updateLocally(message) { $0.isRead = true }
                changeUnreadCount(of: folder, by: -1)
            }
        }
    }

    func closeMessage() {
        openMessage = nil
    }

    // Downloads one of the open message's attachments (or reuses the earlier download).
    func data(for attachment: MailAttachment) async throws -> Data {
        if let alreadyDownloaded = downloadedAttachments[attachment.id] { return alreadyDownloaded }
        statusText = "Downloading \(attachment.filename)…"
        defer { statusText = "Ready" }
        let data = try await attachment.download()
        downloadedAttachments[attachment.id] = data
        return data
    }

    // Downloads attachments and saves each one as a temporary file, for Forward and
    // Edit Draft (the compose window attaches files from disk). Any that fail are
    // left out, and the status bar says which.
    func downloadToTemporaryFiles(_ attachments: [MailAttachment]) async -> [URL] {
        var urls: [URL] = []
        var failedNames: [String] = []
        for attachment in attachments {
            do {
                let data = try await data(for: attachment)
                urls.append(try AttachmentFiles.saveToTemporaryFolder(data, named: attachment.filename))
            } catch {
                failedNames.append(attachment.filename)
            }
        }
        if !failedNames.isEmpty {
            statusText = "Couldn't download: \(failedNames.joined(separator: ", "))"
        }
        return urls
    }

    // MARK: - Changing mail

    // Marks messages read or unread, on the server and on screen.
    func setRead(_ isRead: Bool, for selected: [MailMessage], in folder: MailFolder) async {
        let changing = selected.filter { $0.isRead != isRead }   // skip ones already that way
        guard let account = account(for: folder), !changing.isEmpty else { return }
        await reportingErrors(isRead ? "Marking as read…" : "Marking as unread…", server: account.imapHost) {
            try await IMAPService.setFlag(.seen, to: isRead, uids: changing.map(\.uid), in: folder.path, account: account)
            for message in changing {
                updateLocally(message) { $0.isRead = isRead }
            }
            changeUnreadCount(of: folder, by: isRead ? -changing.count : changing.count)
        }
    }

    // Flags or unflags messages, on the server and on screen.
    func setFlagged(_ isFlagged: Bool, for selected: [MailMessage], in folder: MailFolder) async {
        guard let account = account(for: folder), !selected.isEmpty else { return }
        await reportingErrors(isFlagged ? "Flagging…" : "Clearing flags…", server: account.imapHost) {
            try await IMAPService.setFlag(.flagged, to: isFlagged, uids: selected.map(\.uid), in: folder.path, account: account)
            for message in selected {
                updateLocally(message) { $0.isFlagged = isFlagged }
            }
        }
    }

    // Moves messages to the account's Trash folder, or erases them for good if
    // they're already in Trash (ContentView asks you to confirm that first).
    func deleteMessages(_ selected: [MailMessage], in folder: MailFolder) async {
        guard let account = account(for: folder), !selected.isEmpty else { return }
        if folder.role == .trash {
            await reportingErrors("Deleting…", server: account.imapHost) {
                try await IMAPService.deletePermanently(uids: selected.map(\.uid), in: folder.path, account: account)
                removeLocally(selected, from: folder)
            }
        } else if let trash = self.folder(.trash, in: account) {
            await moveMessages(selected, from: folder, to: trash)
        } else {
            statusText = "Error: This account doesn't have a Trash folder."
        }
    }

    // Moves messages to another folder in the same account.
    func moveMessages(_ selected: [MailMessage], from folder: MailFolder, to destination: MailFolder) async {
        guard let account = account(for: folder), !selected.isEmpty, destination.id != folder.id else { return }
        guard destination.accountID == folder.accountID else {
            statusText = "Messages can only be moved between folders of the same account."
            return
        }
        await reportingErrors("Moving to \(destination.displayName)…", server: account.imapHost) {
            try await IMAPService.moveMessages(uids: selected.map(\.uid), from: folder.path, to: destination.path, account: account)
            removeLocally(selected, from: folder)
            changeUnreadCount(of: destination, by: selected.filter { !$0.isRead }.count)
        }
    }

    // Sends an email from a compose window. Throws if it couldn't be sent, so
    // the compose window can stay open and show why.
    func send(_ draft: ComposeDraft) async throws {
        let account = try sendingAccount(for: draft)
        let email = try makeEmail(from: draft, account: account)

        statusText = "Sending…"
        try await SMTPService.send(email, from: account)
        statusText = "Sent"
        RecentAddresses.remember((email.recipients + email.ccRecipients).map { MailAddress(name: $0.name, address: $0.address) })

        // It's sent, so the saved draft (if any) is no longer needed.
        if let draftUID = draft.savedDraftUID, let draftsFolder = folder(.drafts, in: account) {
            try? await IMAPService.deletePermanently(uids: [draftUID], in: draftsFolder.path, account: account)
        }

        // The email is sent at this point; failing to save a copy shouldn't count as a send failure.
        if !account.provider.savesSentMailAutomatically,
           let sentFolder = folder(.sent, in: account) {
            do {
                try await IMAPService.saveCopy(of: email, to: sentFolder.path, account: account)
            } catch {
                statusText = "Sent, but couldn't save a copy to \(sentFolder.displayName): \(FriendlyError.message(for: error, server: account.imapHost))"
            }
        }
    }

    // Saves a compose window's contents to the Drafts folder, replacing the
    // previously saved version. Returns the new draft's server ID.
    func saveDraft(_ draft: ComposeDraft) async throws -> UInt32? {
        let account = try sendingAccount(for: draft)
        guard let draftsFolder = folder(.drafts, in: account) else {
            throw MailError(message: "This account doesn't have a Drafts folder.")
        }
        let email = try makeEmail(from: draft, account: account)
        let newUID = try await IMAPService.saveDraft(email, to: draftsFolder.path, account: account)
        if let oldUID = draft.savedDraftUID {
            try? await IMAPService.deletePermanently(uids: [oldUID], in: draftsFolder.path, account: account)
        }
        // If you're looking at the Drafts folder, refresh it so the change shows.
        if shownFolderID == draftsFolder.id {
            await loadMessages(in: draftsFolder)
        }
        return newUID
    }

    // MARK: - Helpers

    private func account(for folder: MailFolder) -> AccountSettings? {
        accounts.first { $0.id == folder.accountID }
    }

    // The first folder with a given role (Sent, Drafts…) in an account.
    private func folder(_ role: FolderRole, in account: AccountSettings) -> MailFolder? {
        foldersByAccount[account.id]?.first { $0.role == role }
    }

    private func sendingAccount(for draft: ComposeDraft) throws -> AccountSettings {
        guard let account = accounts.first(where: { $0.id == draft.accountID }) else {
            throw MailError(message: "Choose an account to send from.")
        }
        return account
    }

    // Turns a compose window's contents into SwiftMail's Email, ready to send or save.
    private func makeEmail(from draft: ComposeDraft, account: AccountSettings) throws -> Email {
        var email = Email(
            sender: EmailAddress(name: account.senderName, address: account.emailAddress),
            recipients: try Self.parseAddresses(draft.to),
            ccRecipients: try Self.parseAddresses(draft.cc),
            subject: draft.subject,
            textBody: draft.body,
            htmlBody: draft.htmlBody,
            // `Attachment(fileURL:)` reads each file and works out its type from the extension.
            attachments: try draft.attachmentURLs.map { try Attachment(fileURL: $0) }
        )
        // Giving the email its ID up front means the Sent copy matches what was sent.
        let domain = account.emailAddress.split(separator: "@").last.map(String.init) ?? "localhost"
        email.messageID = MessageID.generate(domain: domain)
        if let inReplyTo = draft.inReplyTo {
            email.additionalHeaders = [
                "In-Reply-To": inReplyTo,
                "References": draft.references.joined(separator: " "),
            ]
        }
        return email
    }

    // Changes our copy of a message (e.g. bold → not bold) without asking the server again.
    // `change` receives the message as `inout`, meaning it can modify it in place.
    private func updateLocally(_ message: MailMessage, change: (inout MailMessage) -> Void) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            change(&messages[index])
        }
    }

    // Takes messages off the list on screen (after a move or delete).
    private func removeLocally(_ removed: [MailMessage], from folder: MailFolder) {
        let removedIDs = Set(removed.map(\.id))
        messages.removeAll { removedIDs.contains($0.id) }
        changeUnreadCount(of: folder, by: -removed.filter { !$0.isRead }.count)
    }

    private func changeUnreadCount(of folder: MailFolder, by change: Int) {
        if let index = foldersByAccount[folder.accountID]?.firstIndex(where: { $0.id == folder.id }) {
            foldersByAccount[folder.accountID]?[index].unreadCount += change
        }
    }

    // Turns "Sarah <sarah@example.com>, tom@example.com" into a list of addresses.
    // Splits at commas or semicolons, but not ones inside quotes or <angle brackets>.
    // Throws if any piece isn't a valid address.
    static func parseAddresses(_ text: String) throws -> [EmailAddress] {
        var pieces: [String] = []
        var current = ""
        var insideQuotes = false
        var insideAngleBrackets = false
        for character in text {
            switch character {
            case "\"": insideQuotes.toggle()
            case "<": insideAngleBrackets = true
            case ">": insideAngleBrackets = false
            case ",", ";":
                if insideQuotes || insideAngleBrackets { break }   // part of a name, keep it
                pieces.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        pieces.append(current)

        return try pieces
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { piece in
                guard let address = EmailAddress(piece) else {
                    throw MailError(message: "“\(piece)” isn't a valid email address.")
                }
                return address
            }
    }

    // Runs a piece of mail work while showing `activity` in the status bar.
    // If the work fails, shows a readable error there instead of crashing.
    // `server` names the server involved, for the error message.
    private func reportingErrors(_ activity: String, server: String, work: () async throws -> Void) async {
        statusText = activity
        do {
            try await work()
            statusText = "Ready"
        } catch is CancellationError {
            // Cancelled because you clicked something else; not a real error.
        } catch {
            statusText = "Error: \(FriendlyError.message(for: error, server: server))"
        }
    }
}
