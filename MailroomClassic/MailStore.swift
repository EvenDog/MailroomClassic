// The app's shared state: the list of accounts, their folders, the messages
// in the folder you're looking at, and the body of the open message. Views
// read from it, and call its functions to add accounts, load, send or change mail.
// Message lists come from the local copy on this Mac (MailCache), which is kept
// up to date with the server in the background (MailSync).

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
    // The last problem checking each account (e.g. a rejected password), shown in
    // the sidebar under that account until a check works again.
    private(set) var accountProblems: [UUID: String] = [:]
    // Accounts being checked right now, so a second check doesn't start on top of
    // one that's still running (which could announce the same new mail twice).
    private var accountsBeingChecked: Set<UUID> = []
    private(set) var isShowingSearchResults = false

    // Which sidebar row (a folder, or All Inboxes) `messages` shows, and the real folders behind it.
    private var shownFolderID: String?
    private var shownFolders: [MailFolder] = []
    // Messages older than the offline window, fetched from the server with
    // "Show Older Messages" (they aren't saved on this Mac), and how many more
    // older ones each shown folder still has on the server.
    private var olderMessages: [MailMessage] = []
    private var olderRemainingByFolder: [MailFolder.ID: Int] = [:]

    // Folders being synced right now, so the same folder is never synced twice at once.
    private var foldersBeingSynced: Set<MailFolder.ID> = []
    private var backgroundSync: Task<Void, Never>?
    private var lastFullSync: Date?

    // Attachments of the open message that are already downloaded, so opening one
    // twice doesn't download it twice. Emptied when another message is opened.
    private var downloadedAttachments: [MailAttachment.ID: Data] = [:]

    // True when the server has messages older than the ones on screen.
    var hasOlderMessages: Bool {
        !isShowingSearchResults && olderRemainingByFolder.values.contains { $0 > 0 }
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
        // A different server or mailbox means the saved copy belongs to something else.
        if accounts[index].imapHost != updated.imapHost || accounts[index].emailAddress != updated.emailAddress {
            try? await MailCache.forgetFolders(ofAccount: updated.id)
        }
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
        accountProblems[account.id] = nil
        AccountStorage.saveAccounts(accounts)
        Task { try? await MailCache.forgetFolders(ofAccount: account.id) }   // and its saved mail
    }

    // MARK: - Reading mail

    // Reloads every account's folder list and unread counts ("Send/Receive"),
    // then starts updating the local copy in the background.
    func refreshAllFolders() async {
        for account in accounts {
            await refreshFolders(for: account)
        }
        startBackgroundSync()
    }

    // Reloads one account's folders and their unread counts, and announces any new
    // mail in its Inbox. The folder list appears first; the counts then arrive one
    // folder at a time (Inbox first), each as its own small job, so opening a
    // message in the meantime doesn't have to wait for every folder to be counted.
    func refreshFolders(for account: AccountSettings) async {
        guard !accountsBeingChecked.contains(account.id) else { return }   // already being checked
        accountsBeingChecked.insert(account.id)
        defer { accountsBeingChecked.remove(account.id) }

        accountProblems[account.id] = await reportingErrors("Checking \(account.displayName)…", server: account.imapHost) {
            let previousFolders = foldersByAccount[account.id] ?? []
            var folders = try await IMAPService.fetchFolders(for: account)
            // Forget saved mail of folders that were deleted or renamed on the server.
            try? await MailCache.forgetFolders(ofAccount: account.id, keeping: folders.map(\.id))
            // Until fresh counts arrive, show the ones from the last check.
            for index in folders.indices {
                if let previous = previousFolders.first(where: { $0.id == folders[index].id }) {
                    folders[index].unreadCount = previous.unreadCount
                    folders[index].uidNext = previous.uidNext
                }
            }
            foldersByAccount[account.id] = folders

            for folder in folders {   // already sorted Inbox first
                // `try?`: if one folder can't be counted, keep its old count and carry on.
                guard let counts = try? await IMAPService.fetchCounts(of: folder, account: account),
                      let index = foldersByAccount[account.id]?.firstIndex(where: { $0.id == folder.id }) else { continue }
                foldersByAccount[account.id]?[index].unreadCount = counts.unread
                foldersByAccount[account.id]?[index].uidNext = counts.uidNext

                // If the Inbox's "next message ID" went up since last time, new mail arrived.
                // (On the first check there's nothing to compare with, so no alerts.)
                guard folder.role == .inbox,
                      let oldNext = previousFolders.first(where: { $0.id == folder.id })?.uidNext,
                      let newNext = counts.uidNext, newNext > oldNext else { continue }
                // `try?`: if fetching the details fails, skip the alert rather than failing the check.
                let arrivals = (try? await IMAPService.fetchNewMessages(for: account, folderPath: folder.path, firstNewUID: oldNext)) ?? []
                NewMailNotifier.announce(arrivals.filter { !$0.isRead }, account: account)
            }
        }
    }

    // Shows the newest messages in a folder (the first page of them).
    func loadMessages(in folder: MailFolder) async {
        await loadMessages(from: [folder], viewID: folder.id)
    }

    // Shows the messages in one or more folders, mixed together newest first
    // (several folders means All Inboxes). They appear straight away from the
    // local copy, then each folder is synced with the server and the list updates.
    // `viewID` is the sidebar row being shown (a folder's ID, or MailFolder.allInboxesID).
    func loadMessages(from folders: [MailFolder], viewID: String) async {
        if shownFolderID != viewID {
            messages = []
            olderMessages = []
            olderRemainingByFolder = [:]
        }
        shownFolderID = viewID
        shownFolders = folders
        isShowingSearchResults = false
        await showSavedMessages()
        for folder in folders {
            await sync(folder)
        }
    }

    // "Show Older Messages": fetches the next page of messages older than the
    // offline window from the server (they aren't kept on this Mac).
    func loadOlderMessages(from folders: [MailFolder], viewID: String) async {
        let foldersWithMore = folders.filter { (olderRemainingByFolder[$0.id] ?? 0) > 0 }
        let fetched = await collectMessages(from: foldersWithMore, activity: "Loading older messages…") { account, folder in
            let alreadyShown = olderMessages.filter { $0.folderID == folder.id }.count
            return try await IMAPService.fetchOlderMessages(in: folder, before: OfflineWindow.startDate, skipping: alreadyShown,
                                                            limit: IMAPService.pageSize, account: account)
        }
        guard let fetched, shownFolderID == viewID else { return }
        for folder in foldersWithMore {
            let count = fetched.filter { $0.folderID == folder.id }.count
            // Fewer than a full page means that was the last of them.
            olderRemainingByFolder[folder.id] = count < IMAPService.pageSize ? 0 : max(0, (olderRemainingByFolder[folder.id] ?? 0) - count)
        }
        olderMessages += fetched
        await showSavedMessages()
    }

    // Puts the shown folders' saved messages on screen, plus any older ones
    // fetched from the server, newest first.
    private func showSavedMessages() async {
        guard let viewID = shownFolderID else { return }
        do {
            let saved = try await MailCache.messages(inFolders: shownFolders.map(\.id))
            guard shownFolderID == viewID, !isShowingSearchResults else { return }   // you moved on meanwhile
            messages = (saved + olderMessages).sorted { $0.dateReceived > $1.dateReceived }
        } catch {
            statusText = "Error: Couldn't read the saved mail on this Mac (\(error.localizedDescription))."
        }
    }

    // Brings one folder's local copy up to date with the server, refreshing the
    // message list as changes arrive if that folder is on screen.
    func sync(_ folder: MailFolder) async {
        guard let account = account(for: folder), !foldersBeingSynced.contains(folder.id) else { return }
        foldersBeingSynced.insert(folder.id)
        defer { foldersBeingSynced.remove(folder.id) }

        await reportingErrors("Updating \(folder.displayName)…", server: account.imapHost) {
            let olderOnServer = try await MailSync.sync(folder, account: account) {
                if self.isShowing(folder) { await self.showSavedMessages() }
            }
            if isShowing(folder) {
                let alreadyShown = olderMessages.filter { $0.folderID == folder.id }.count
                olderRemainingByFolder[folder.id] = max(0, olderOnServer - alreadyShown)
            }
        }
    }

    // Updates the local copy without waiting: every account's Inbox after each
    // check, and every other folder too at least every 30 minutes. Accounts sync
    // side by side; within one account it's one folder at a time, Inbox first.
    func startBackgroundSync() {
        guard backgroundSync == nil else { return }   // the last one is still going
        let includeEveryFolder = lastFullSync.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true
        if includeEveryFolder { lastFullSync = Date() }
        let foldersByAccount = accounts.map { account in
            (self.foldersByAccount[account.id] ?? []).filter { includeEveryFolder || $0.role == .inbox }
        }
        backgroundSync = Task {
            // A task group runs several pieces of work at the same time (here, one per account)
            // and waits until they've all finished.
            await withTaskGroup(of: Void.self) { group in
                for folders in foldersByAccount {
                    group.addTask {
                        for folder in folders {
                            await self.sync(folder)
                        }
                    }
                }
            }
            backgroundSync = nil
        }
    }

    private func isShowing(_ folder: MailFolder) -> Bool {
        !isShowingSearchResults && shownFolders.contains { $0.id == folder.id }
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
                // `try?`: if the local copy can't be updated, the next sync corrects it.
                try? await MailCache.setFlags({ $0.isRead = true }, for: [message])
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
            try? await MailCache.setFlags({ $0.isRead = isRead }, for: changing)   // the next sync corrects any failure
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
            try? await MailCache.setFlags({ $0.isFlagged = isFlagged }, for: selected)   // the next sync corrects any failure
        }
    }

    // Moves messages to the account's Trash folder, or erases them for good if
    // they're already in Trash (ContentView asks you to confirm that first).
    func deleteMessages(_ selected: [MailMessage], in folder: MailFolder) async {
        guard let account = account(for: folder), !selected.isEmpty else { return }
        if folder.role == .trash {
            await reportingErrors("Deleting…", server: account.imapHost) {
                try await IMAPService.deletePermanently(uids: selected.map(\.uid), in: folder.path, account: account)
                await removeLocally(selected, from: folder)
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
            await removeLocally(selected, from: folder)
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

    // Takes messages off the list on screen and out of the local copy (after a move or delete).
    private func removeLocally(_ removed: [MailMessage], from folder: MailFolder) async {
        let removedIDs = Set(removed.map(\.id))
        messages.removeAll { removedIDs.contains($0.id) }
        olderMessages.removeAll { removedIDs.contains($0.id) }
        changeUnreadCount(of: folder, by: -removed.filter { !$0.isRead }.count)
        try? await MailCache.remove(removed)   // the next sync corrects any failure
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
    // Returns the error message, or nil if it worked (`@discardableResult`: callers may ignore it).
    @discardableResult
    private func reportingErrors(_ activity: String, server: String, work: () async throws -> Void) async -> String? {
        statusText = activity
        do {
            try await work()
            statusText = "Ready"
        } catch is CancellationError {
            // Cancelled because you clicked something else; not a real error.
        } catch {
            let message = FriendlyError.message(for: error, server: server)
            statusText = "Error: \(message)"
            return message
        }
        return nil
    }
}
