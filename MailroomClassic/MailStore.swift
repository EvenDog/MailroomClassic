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
    private(set) var foldersByAccount: [UUID: [MailFolder]] = [:]
    private(set) var messages: [MailMessage] = []
    private(set) var openMessage: OpenMessage?   // the full contents of the message in the reading pane
    private(set) var statusText = "Ready"
    private(set) var isShowingSearchResults = false

    // Which folder `messages` came from, how many we asked for, and how many the folder holds.
    private var shownFolderID: MailFolder.ID?
    private var messageLimit = IMAPService.pageSize
    private var totalMessageCount = 0

    // True when the folder has messages older than the ones on screen.
    var hasOlderMessages: Bool {
        !isShowingSearchResults && messages.count < totalMessageCount
    }

    // Every folder from every account, in one list.
    var allFolders: [MailFolder] {
        accounts.flatMap { foldersByAccount[$0.id] ?? [] }
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

    func refreshFolders(for account: AccountSettings) async {
        await reportingErrors("Checking \(account.displayName)…") {
            foldersByAccount[account.id] = try await IMAPService.fetchFolders(for: account)
        }
    }

    // Shows the newest messages in a folder (the first page of them).
    func loadMessages(in folder: MailFolder) async {
        if shownFolderID != folder.id {
            messages = []
            messageLimit = IMAPService.pageSize
        }
        shownFolderID = folder.id
        isShowingSearchResults = false
        await fetchMessages(in: folder, activity: "Loading \(folder.displayName)…")
    }

    // "Show older messages": loads another page further back in time.
    func loadOlderMessages(in folder: MailFolder) async {
        messageLimit += IMAPService.pageSize
        await fetchMessages(in: folder, activity: "Loading older messages…")
    }

    // Replaces the message list with the server's search results for `query`.
    func search(_ query: String, in folder: MailFolder) async {
        guard let account = account(for: folder) else { return }
        await reportingErrors("Searching \(folder.displayName)…") {
            let results = try await IMAPService.searchMessages(for: account, folderPath: folder.path, query: query)
            guard shownFolderID == folder.id else { return }   // you switched folders meanwhile
            messages = results.sorted { $0.dateReceived > $1.dateReceived }
            isShowingSearchResults = true
        }
        if isShowingSearchResults {
            statusText = messages.count == 1 ? "1 message found" : "\(messages.count) messages found"
        }
    }

    private func fetchMessages(in folder: MailFolder, activity: String) async {
        guard let account = account(for: folder) else { return }
        await reportingErrors(activity) {
            let page = try await IMAPService.fetchLatestMessages(for: account, folderPath: folder.path, limit: messageLimit)
            // If you clicked another folder while this was loading, throw this result away.
            guard !Task.isCancelled, shownFolderID == folder.id else { return }
            messages = page.messages.sorted { $0.dateReceived > $1.dateReceived }
            totalMessageCount = page.totalCount
        }
    }

    // Downloads a whole message (text, HTML, attachments) and marks it as read.
    func open(_ message: MailMessage, in folder: MailFolder) async {
        openMessage = nil
        guard let account = account(for: folder) else { return }
        await reportingErrors("Opening message…") {
            let contents = try await IMAPService.fetchFullMessage(for: account, folderPath: folder.path, uid: message.uid)
            guard !Task.isCancelled else { return }
            openMessage = contents
            if !message.isRead {
                updateLocally(message) { $0.isRead = true }
                changeUnreadCount(of: folder, by: -1)
            }
        }
    }

    func closeMessage() {
        openMessage = nil
    }

    // MARK: - Changing mail

    // Marks a message read or unread, on the server and on screen.
    func setRead(_ isRead: Bool, for message: MailMessage, in folder: MailFolder) async {
        guard let account = account(for: folder), message.isRead != isRead else { return }
        await reportingErrors(isRead ? "Marking as read…" : "Marking as unread…") {
            try await IMAPService.setFlag(.seen, to: isRead, uid: message.uid, in: folder.path, account: account)
            updateLocally(message) { $0.isRead = isRead }
            changeUnreadCount(of: folder, by: isRead ? -1 : 1)
        }
    }

    // Flags or unflags a message, on the server and on screen.
    func setFlagged(_ isFlagged: Bool, for message: MailMessage, in folder: MailFolder) async {
        guard let account = account(for: folder) else { return }
        await reportingErrors(isFlagged ? "Flagging…" : "Clearing flag…") {
            try await IMAPService.setFlag(.flagged, to: isFlagged, uid: message.uid, in: folder.path, account: account)
            updateLocally(message) { $0.isFlagged = isFlagged }
        }
    }

    // Moves a message to the account's Trash folder, or erases it for good if
    // it's already in Trash (ContentView asks you to confirm that first).
    func deleteMessage(_ message: MailMessage, in folder: MailFolder) async {
        guard let account = account(for: folder) else { return }
        await reportingErrors("Deleting…") {
            if folder.role == .trash {
                try await IMAPService.deletePermanently(uid: message.uid, in: folder.path, account: account)
            } else {
                guard let trash = foldersByAccount[account.id]?.first(where: { $0.role == .trash }) else {
                    throw MailError(message: "This account doesn't have a Trash folder.")
                }
                try await IMAPService.moveMessage(uid: message.uid, from: folder.path, to: trash.path, account: account)
            }
            messages.removeAll { $0.id == message.id }
            if !message.isRead {
                changeUnreadCount(of: folder, by: -1)
            }
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

        // It's sent, so the saved draft (if any) is no longer needed.
        if let draftUID = draft.savedDraftUID, let draftsFolder = folder(.drafts, in: account) {
            try? await IMAPService.deletePermanently(uid: draftUID, in: draftsFolder.path, account: account)
        }

        // The email is sent at this point; failing to save a copy shouldn't count as a send failure.
        if !account.provider.savesSentMailAutomatically,
           let sentFolder = folder(.sent, in: account) {
            do {
                try await IMAPService.saveCopy(of: email, to: sentFolder.path, account: account)
            } catch {
                statusText = "Sent, but couldn't save a copy to \(sentFolder.displayName): \(error.localizedDescription)"
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
            try? await IMAPService.deletePermanently(uid: oldUID, in: draftsFolder.path, account: account)
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
    // If the work fails, shows the error there instead of crashing.
    private func reportingErrors(_ activity: String, work: () async throws -> Void) async {
        statusText = activity
        do {
            try await work()
            statusText = "Ready"
        } catch is CancellationError {
            // Cancelled because you clicked something else; not a real error.
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }
}
