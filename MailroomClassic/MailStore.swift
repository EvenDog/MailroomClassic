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
    private(set) var rules: [MailRule] = RuleStorage.loadRules()
    private(set) var foldersByAccount: [UUID: [MailFolder]] = [:] {
        // `didSet` runs after every change: keep the Dock badge's unread count up to date.
        didSet { NewMailNotifier.updateDockBadge(unreadCount: unreadInboxCount) }
    }
    private(set) var messages: [MailMessage] = []
    // The start of each shown message's text, by message ID, for the message list's
    // preview line (View → Preview Text). Only messages whose contents are saved have one.
    private(set) var previews: [MailMessage.ID: String] = [:]
    private(set) var openMessage: OpenMessage?   // the full contents of the message in the reading pane
    // How to unsubscribe from the open message's mailing list (see Unsubscribe), looked
    // up after it opens. It carries the message's ID so the reading pane only shows the
    // button on the message it belongs to, even if you've clicked on since.
    private(set) var unsubscribeOffer: (messageID: MailMessage.ID, method: UnsubscribeMethod)?
    private(set) var statusText = "Ready"
    // The last problem checking each account (e.g. a rejected password), shown in
    // the sidebar under that account until a check works again.
    private(set) var accountProblems: [UUID: String] = [:]
    // Accounts being checked right now, so a second check doesn't start on top of
    // one that's still running (which could announce the same new mail twice).
    private var accountsBeingChecked: Set<UUID> = []
    private(set) var isShowingSearchResults = false
    private(set) var searchCoversAllFolders = false   // the results come from every folder (so show a Folder column)
    private var activeSearch: String?   // the search being shown, so a slow server reply for an old one is ignored

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
    // When every folder last finished syncing. Saved in UserDefaults so that
    // reopening the app soon after quitting syncs only the Inboxes, not every folder.
    private var lastFullSync: Date? {
        get { UserDefaults.standard.object(forKey: "lastFullSync") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastFullSync") }
    }
    // Downloading message contents ahead of time (see downloadForOffline), and its
    // progress for the status bar, e.g. "Downloading for offline reading: 400 of 1,975".
    private var offlineDownload: Task<Void, Never>?
    private(set) var offlineDownloadProgress: String?
    private var offlineDownloadDone = 0
    // Set when another download is asked for while one is running, so it runs again
    // afterwards (e.g. for an account added in the meantime).
    private var offlineDownloadRequestedAgain = false
    private var offlineDownloadTotal = 0

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
        // Fill in the new account's saved copy now, rather than at the next full sync.
        // `Task` starts it without waiting, so the Settings window is done straight away.
        Task { await syncEveryFolder(of: account) }
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
        let isDifferentMailbox = accounts[index].imapHost != updated.imapHost || accounts[index].emailAddress != updated.emailAddress
        if isDifferentMailbox {
            try? await MailCache.forgetFolders(ofAccount: updated.id)
        }
        accounts[index] = updated
        AccountStorage.saveAccounts(accounts)
        // The open connections still use the old settings, so start new ones.
        // (Refreshing the folders below starts push again.)
        stopPush(for: updated.id)
        await IMAPService.closeConnection(for: updated.id)
        await refreshFolders(for: updated)
        if isDifferentMailbox {
            Task { await syncEveryFolder(of: updated) }   // fill in the new mailbox's saved copy
        }
    }

    func removeAccount(_ account: AccountSettings) {
        stopPush(for: account.id)
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

    // At launch: shows each account's folders from the last check, so the
    // sidebar and the saved mail appear straight away, even with no internet.
    // The next check replaces them with fresh ones.
    func showSavedFolders() async {
        guard let saved = try? await MailCache.folderLists() else { return }
        for account in accounts where foldersByAccount[account.id] == nil {
            guard var folders = saved[account.id] else { continue }
            // Forget the saved "next message ID"s: mail that came in while the app
            // was closed shouldn't pop up as a pile of new-mail alerts at launch.
            for index in folders.indices { folders[index].uidNext = nil }
            foldersByAccount[account.id] = folders
        }
    }

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
            let previousFolders = try await reloadFolderList(for: account)

            for folder in foldersByAccount[account.id] ?? [] {   // already sorted Inbox first
                let oldNext = previousFolders.first(where: { $0.id == folder.id })?.uidNext
                await updateCounts(of: folder, account: account, previousUIDNext: oldNext)
            }
            // Save the fresh counts for next launch. (`try?`: not worth failing the check over.)
            try? await MailCache.saveFolderList(foldersByAccount[account.id] ?? [], for: account.id)
        }
        startPush(for: account)   // does nothing if it's already running (or turned off)
    }

    // Asks the server for one folder's unread count and the ID its next new message
    // will get. For an Inbox, if that ID went up since `previousUIDNext`, new mail
    // arrived, so it's announced. (With no earlier ID to compare, e.g. on the first
    // check, there are no alerts.) If the folder can't be counted, it keeps its old count.
    private func updateCounts(of folder: MailFolder, account: AccountSettings, previousUIDNext: UInt32?) async {
        guard let counts = try? await IMAPService.fetchCounts(of: folder, account: account),
              let index = foldersByAccount[account.id]?.firstIndex(where: { $0.id == folder.id }) else { return }
        foldersByAccount[account.id]?[index].unreadCount = counts.unread
        foldersByAccount[account.id]?[index].uidNext = counts.uidNext

        guard folder.role == .inbox, let oldNext = previousUIDNext,
              let newNext = counts.uidNext, newNext > oldNext else { return }
        // `try?`: if fetching the details fails, skip the alert rather than failing the check.
        let arrivals = (try? await IMAPService.fetchNewMessages(for: account, folderPath: folder.path, firstNewUID: oldNext)) ?? []
        NewMailNotifier.announce(arrivals.filter { !$0.isRead }, account: account)
    }

    // MARK: - Push (see PushWatcher)

    // Each account's push watcher, while one is running.
    private var pushWatchers: [UUID: PushWatcher] = [:]

    // Starts watching an account's Inbox, Sent and Drafts for changes, unless
    // that's already happening, push is turned off in Settings, or its folders
    // aren't known yet.
    func startPush(for account: AccountSettings) {
        guard PushWatcher.isEnabled, pushWatchers[account.id] == nil else { return }
        let folders = PushWatcher.watchedRoles.compactMap { folder($0, in: account) }
        guard !folders.isEmpty else { return }
        pushWatchers[account.id] = PushWatcher(account: account, folders: folders) { [weak self] folder in
            await self?.folderChangedOnServer(folder)
        }
    }

    func stopPush(for accountID: UUID) {
        pushWatchers[accountID]?.stop()
        pushWatchers[accountID] = nil
    }

    // Stops every watcher and starts them again (if push is on): after the Mac
    // wakes from sleep, whose dropped connections would otherwise take minutes
    // to notice, and when push is turned on or off in Settings.
    func restartPush() {
        for accountID in pushWatchers.keys {
            stopPush(for: accountID)
        }
        for account in accounts {
            startPush(for: account)
        }
    }

    // The server says a watched folder changed: count it (announcing new Inbox
    // mail), then update its saved copy and, if it's on screen, the message list.
    private func folderChangedOnServer(_ folder: MailFolder) async {
        guard let account = account(for: folder),
              let current = foldersByAccount[account.id]?.first(where: { $0.id == folder.id }) else { return }
        // If the folder is already being updated (e.g. by the regular check), let
        // that finish first: the change may have arrived after it looked.
        await waitForSyncToFinish(of: folder)
        await updateCounts(of: current, account: account, previousUIDNext: current.uidNext)
        await sync(current)
    }

    // Waits while a folder is being synced (`sync` skips a folder that's already
    // being synced, so a sync that must really happen waits for that one first).
    private func waitForSyncToFinish(of folder: MailFolder) async {
        while foldersBeingSynced.contains(folder.id) {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // Asks the server for an account's folder list and shows it. Until fresh counts
    // arrive, each folder keeps the counts from the last check. Returns the old list.
    @discardableResult
    private func reloadFolderList(for account: AccountSettings) async throws -> [MailFolder] {
        let previousFolders = foldersByAccount[account.id] ?? []
        var folders = try await IMAPService.fetchFolders(for: account)
        // Forget saved mail of folders that were deleted or renamed on the server.
        try? await MailCache.forgetFolders(ofAccount: account.id, keeping: folders.map(\.id))
        for index in folders.indices {
            if let previous = previousFolders.first(where: { $0.id == folders[index].id }) {
                folders[index].unreadCount = previous.unreadCount
                folders[index].uidNext = previous.uidNext
            }
        }
        foldersByAccount[account.id] = folders
        try? await MailCache.saveFolderList(folders, for: account.id)
        return previousFolders
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
        searchCoversAllFolders = false
        activeSearch = nil
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
        await refreshPreviews()
    }

    // Reloads the preview lines for the shown folders' messages from the saved copy.
    private func refreshPreviews() async {
        // `try?`: without previews the list still works, just with subjects only.
        guard let loaded = try? await MailCache.previews(inFolders: shownFolders.map(\.id)) else { return }
        previews = loaded
    }

    // Brings one folder's local copy up to date with the server, refreshing the
    // message list as changes arrive if that folder is on screen.
    func sync(_ folder: MailFolder) async {
        guard let account = account(for: folder), !foldersBeingSynced.contains(folder.id) else { return }
        foldersBeingSynced.insert(folder.id)
        defer { foldersBeingSynced.remove(folder.id) }

        var arrivals: [MailMessage] = []
        await reportingErrors("Updating \(folder.displayName)…", server: account.imapHost) {
            let result = try await MailSync.sync(folder, account: account) {
                if self.isShowing(folder) { await self.showSavedMessages() }
            }
            arrivals = result.arrivals
            if isShowing(folder) {
                let alreadyShown = olderMessages.filter { $0.folderID == folder.id }.count
                olderRemainingByFolder[folder.id] = max(0, result.olderOnServer - alreadyShown)
            }
        }
        if folder.role == .inbox && !arrivals.isEmpty {
            await applyRules(to: arrivals, in: folder)
        }
    }

    // Updates the local copy without waiting: every account's Inbox after each
    // check, and every other folder too at least every 30 minutes. Accounts sync
    // side by side; within one account it's one folder at a time, Inbox first.
    func startBackgroundSync() {
        guard backgroundSync == nil else { return }   // the last one is still going
        let includeEveryFolder = lastFullSync.map { Date().timeIntervalSince($0) > 30 * 60 } ?? true
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
            // Noted only once it's finished, so quitting partway through means
            // the next launch does the full sync again.
            if includeEveryFolder { lastFullSync = Date() }
            backgroundSync = nil
            downloadForOffline()
        }
    }

    // One account's part of downloadForOffline, batch by batch.
    private func downloadForOffline(_ work: [(folder: MailFolder, messages: [MailMessage])], account: AccountSettings) async {
        // `defer` runs when this function finishes, however it finishes (including the `return` below).
        defer { Task { await IMAPService.closeDownloadingConnection(for: account.id) } }
        // A pause between batches, longer for Gmail, which slows down accounts that
        // download a lot quickly (see LoginBackoff).
        let pauseBetweenBatches: Duration = account.provider == .gmail ? .seconds(5) : .seconds(1)
        for (folder, messages) in work {
            for start in stride(from: 0, to: messages.count, by: Self.offlineBatchSize) {
                let batch = Array(messages[start ..< min(start + Self.offlineBatchSize, messages.count)])
                // If a batch fails (e.g. the Wi-Fi dropped), stop this account for now;
                // the next run picks up where this one stopped.
                guard let bodies = try? await IMAPService.fetchBodies(uids: batch.map(\.uid), in: folder.path, account: account) else {
                    return
                }
                try? await MailCache.saveBodies(batch.compactMap { message in
                    bodies[message.uid].map { (message: message, body: $0) }
                })
                offlineDownloadDone += batch.count
                showOfflineDownloadProgress()
                if isShowing(folder) { await refreshPreviews() }   // so their preview lines appear
                try? await Task.sleep(for: pauseBetweenBatches)
            }
        }
    }

    private func showOfflineDownloadProgress() {
        offlineDownloadProgress = offlineDownloadDone < offlineDownloadTotal
            ? "Downloading for offline reading: \(offlineDownloadDone.formatted()) of \(offlineDownloadTotal.formatted())"
            : nil
    }

    // Syncs every folder of one account (Inbox first), then downloads its messages
    // for offline reading. Used right after an account is added.
    private func syncEveryFolder(of account: AccountSettings) async {
        for folder in foldersByAccount[account.id] ?? [] {
            await sync(folder)
        }
        downloadForOffline()
    }

    // How many messages to download per batch when downloading ahead of time.
    private static let offlineBatchSize = 50

    // Downloads the contents of saved messages that haven't been opened yet, so
    // every message opens instantly and can be read offline, like classic Outlook.
    // Runs on each account's "downloading" connection, newest first, folder by folder
    // (Inbox first), and saves each batch as it arrives, so stopping halfway loses
    // nothing. Skips All Mail (it repeats the other folders), Spam and Trash; those
    // messages are still saved once you open them. Runs after each background sync,
    // so after the first big download it only fetches new mail.
    func downloadForOffline() {
        guard offlineDownload == nil else {   // still going: run again when it's done
            offlineDownloadRequestedAgain = true
            return
        }
        let foldersByAccount = accounts.map { account in
            (self.foldersByAccount[account.id] ?? []).filter { ![.allMail, .junk, .trash].contains($0.role) }
        }
        offlineDownload = Task {
            // What's still to download, folder by folder. Each message is tried once per
            // run, so one that keeps failing (e.g. deleted on the server) can't loop forever.
            var waiting: [(folder: MailFolder, messages: [MailMessage])] = []
            for folder in foldersByAccount.joined() {
                if let missing = try? await MailCache.messagesWithoutBody(inFolder: folder.id), !missing.isEmpty {
                    waiting.append((folder, missing))
                }
            }
            offlineDownloadTotal = waiting.reduce(0) { $0 + $1.messages.count }
            offlineDownloadDone = 0
            showOfflineDownloadProgress()

            // Accounts download side by side; within one account, one batch at a time.
            await withTaskGroup(of: Void.self) { group in
                for account in accounts {
                    let accountWork = waiting.filter { $0.folder.accountID == account.id }
                    group.addTask { await self.downloadForOffline(accountWork, account: account) }
                }
            }
            offlineDownloadProgress = nil
            offlineDownload = nil
            if offlineDownloadRequestedAgain {
                offlineDownloadRequestedAgain = false
                downloadForOffline()
            }
        }
    }

    private func isShowing(_ folder: MailFolder) -> Bool {
        !isShowingSearchResults && shownFolders.contains { $0.id == folder.id }
    }

    // Replaces the message list with search results for `query`, in two steps:
    // first, instantly, the saved messages whose sender, recipients or subject
    // match; then the server's results are added, which also search the message
    // text and mail older than the offline window (and work even if nothing is saved yet).
    func search(_ query: String, in folders: [MailFolder], viewID: String) async {
        activeSearch = query
        searchCoversAllFolders = false
        if let saved = try? await MailCache.search(query, inFolders: folders.map(\.id)),
           shownFolderID == viewID, activeSearch == query {
            messages = saved
            isShowingSearchResults = true
        }

        let name = folders.count == 1 ? folders[0].displayName : "All Inboxes"
        let fromServer = await collectMessages(from: folders, activity: "Searching \(name) on the server…") { account, folder in
            try await IMAPService.searchMessages(for: account, folderPath: folder.path, query: query)
        }
        // Stop if you switched folders or searched again meanwhile.
        guard shownFolderID == viewID, activeSearch == query else { return }
        if let fromServer {
            // Combine both lists. A message in both appears once, with the server's (newer) read/flag status.
            var combined = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for message in fromServer {
                combined[message.id] = message
            }
            messages = combined.values.sorted { $0.dateReceived > $1.dateReceived }
            isShowingSearchResults = true
        }
        if statusText == "Ready" {   // don't hide an error (the saved results still show if the server failed)
            statusText = messages.count == 1 ? "1 message found" : "\(messages.count) messages found"
        }
    }

    // Search → All Folders: every folder of every account, from the copy saved on
    // this Mac (the last 12 months; sender, recipients and subject). The servers
    // aren't asked: that would be one request per folder, dozens in all, and Gmail
    // slows down accounts that make lots of requests.
    func searchAllFolders(_ query: String, viewID: String) async {
        activeSearch = query
        guard let saved = try? await MailCache.search(query, inFolders: allFolders.map(\.id)),
              shownFolderID == viewID, activeSearch == query else { return }
        messages = withoutGmailDuplicates(saved)
        isShowingSearchResults = true
        searchCoversAllFolders = true
        statusText = messages.count == 1 ? "1 message found in all folders" : "\(messages.count) messages found in all folders"
    }

    // Gmail's All Mail holds a second copy of every message that's also in another
    // folder. Keeps one of each (the one in the other folder), matching copies by
    // their worldwide-unique Message-ID within the same account. Keeps the order.
    private func withoutGmailDuplicates(_ found: [MailMessage]) -> [MailMessage] {
        var kept: [MailMessage] = []
        var positionByKey: [String: Int] = [:]   // "account|Message-ID" → where it is in `kept`
        for message in found {
            guard let folder = folder(of: message), let messageID = message.messageID else {
                kept.append(message)
                continue
            }
            let key = "\(folder.accountID)|\(messageID)"
            if let position = positionByKey[key] {
                // Already have a copy: swap it for this one if the one we have is the All Mail copy.
                if self.folder(of: kept[position])?.role == .allMail {
                    kept[position] = message
                }
            } else {
                positionByKey[key] = kept.count
                kept.append(message)
            }
        }
        return kept
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

    // Shows a whole message (text, HTML, list of attachments), then marks it as read,
    // straight away or after the wait chosen in Settings (see markAsReadDelaySeconds).
    // A message opened before comes from the copy saved on this Mac; otherwise it's
    // downloaded and saved for next time.
    func open(_ message: MailMessage, in folder: MailFolder) async {
        openMessage = nil
        unsubscribeOffer = nil
        downloadedAttachments = [:]
        guard let account = account(for: folder) else { return }
        var isShown = false
        await reportingErrors("Opening message…", server: account.imapHost) {
            let contents = try await loadContents(of: message, in: folder, account: account)
            guard !Task.isCancelled else { return }
            openMessage = contents
            isShown = true
            // Remember the sender for To/Cc suggestions (but not junk mail senders).
            if folder.role != .junk {
                RecentAddresses.remember([message.sender])
            }
        }
        guard isShown else { return }
        lookUpUnsubscribe(for: message, in: folder, account: account)
        guard !message.isRead else { return }

        // Wait first, if Settings says to. Clicking another message cancels this
        // task (see ContentView), which ends the wait early, so the message stays unread.
        let delay = UserDefaults.standard.integer(forKey: Self.markAsReadDelayKey)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
        }
        // Skip it if it was marked read some other way during the wait (e.g. ⇧⌘U).
        guard messages.first(where: { $0.id == message.id })?.isRead == false else { return }
        updateLocally(message) { $0.isRead = true }
        changeUnreadCount(of: folder, by: -1)
        // `try?`: if the local copy can't be updated, the next sync corrects it.
        try? await MailCache.setFlags({ $0.isRead = true }, for: [message])
        // Tell the server last, so the message shows a second sooner on slow servers.
        // (If this fails, the next sync makes the message bold again rather than hiding it.)
        try? await IMAPService.markAsRead(uid: message.uid, in: folder.path, account: account)
    }

    // The setting (in UserDefaults) for how many seconds a message is shown before
    // it's marked as read. 0, the default, means straight away.
    static let markAsReadDelayKey = "markAsReadDelaySeconds"

    func closeMessage() {
        openMessage = nil
        unsubscribeOffer = nil
    }

    // Finds out in the background whether the open message can be unsubscribed from,
    // so the reading pane can show its Unsubscribe button. `Task { }` starts it without
    // waiting, so marking the message as read isn't held up. Skipped in Junk, because
    // unsubscribing from spam only tells the spammer your address works. Problems
    // (e.g. being offline) are ignored: the button just doesn't appear.
    private func lookUpUnsubscribe(for message: MailMessage, in folder: MailFolder, account: AccountSettings) {
        guard folder.role != .junk else { return }
        Task {
            if let method = try? await IMAPService.fetchUnsubscribeMethod(uid: message.uid, in: folder.path, account: account) {
                unsubscribeOffer = (messageID: message.id, method: method)
            }
        }
    }

    // Unsubscribes from a message's mailing list with a one-click request, or by
    // sending the list an email from the account the message came to. (Lists that
    // only offer a web page are opened in the browser by the reading pane instead.)
    // The email isn't saved in Sent, since it's just a note to a machine.
    func unsubscribe(from message: MailMessage, using method: UnsubscribeMethod) async {
        guard let folder = folder(of: message), let account = account(for: folder) else { return }
        let listName = message.senderDisplayName
        var server = account.smtpHost
        if case .oneClick(let url) = method { server = url.host() ?? server }
        let problem = await reportingErrors("Unsubscribing from \(listName)…", server: server) {
            switch method {
            case .oneClick(let url):
                try await UnsubscribeMethod.unsubscribeWithOneClick(at: url)
            case .email(let address, let subject, let body):
                let email = Email(
                    sender: EmailAddress(name: account.senderName, address: account.emailAddress),
                    recipients: [EmailAddress(address: address)],
                    subject: subject,
                    textBody: body
                )
                try await SMTPService.send(email, from: account)
            case .webPage:
                break
            }
        }
        guard problem == nil else { return }
        statusText = "Unsubscribed from \(listName)"
        // Hide the button: it's done.
        if unsubscribeOffer?.messageID == message.id {
            unsubscribeOffer = nil
        }
    }

    // A message's contents for its own window (double-click). Unlike `open`, this
    // leaves the reading pane alone. Returns nil if it couldn't be loaded (the status bar says why).
    func contents(of message: MailMessage) async -> OpenMessage? {
        guard let folder = folder(of: message), let account = account(for: folder) else { return nil }
        var contents: OpenMessage?
        await reportingErrors("Opening message…", server: account.imapHost) {
            contents = try await loadContents(of: message, in: folder, account: account)
        }
        return contents
    }

    // The copy of a message saved on this Mac, or else downloads it (and saves it for next time).
    private func loadContents(of message: MailMessage, in folder: MailFolder, account: AccountSettings) async throws -> OpenMessage {
        // `try?`: if the saved copy can't be read, just download it again.
        var body = try? await MailCache.body(of: message)
        if body == nil {
            body = try await IMAPService.fetchBody(for: account, folderPath: folder.path, uid: message.uid)
            if let body {
                try? await MailCache.saveBody(body, for: message)   // not saved: it just downloads again next time
            }
        }
        return body.map { IMAPService.openMessage(from: $0, uid: message.uid, folderPath: folder.path, account: account) }
            ?? OpenMessage(plainText: "(This message could not be found on the server.)", html: nil, attachments: [])
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

    // Marks messages read or unread, on screen straight away, then on the server.
    // (Like moves, see moveMessages: if the server refuses, the screen is put back.)
    func setRead(_ isRead: Bool, for selected: [MailMessage], in folder: MailFolder) async {
        let changing = selected.filter { $0.isRead != isRead }   // skip ones already that way
        guard let account = account(for: folder), !changing.isEmpty else { return }
        for message in changing {
            updateLocally(message) { $0.isRead = isRead }
        }
        let unreadChange = isRead ? -changing.count : changing.count
        changeUnreadCount(of: folder, by: unreadChange)
        let problem = await reportingErrors(isRead ? "Marking as read…" : "Marking as unread…", server: account.imapHost) {
            try await IMAPService.setFlag(.seen, to: isRead, uids: changing.map(\.uid), in: folder.path, account: account)
            try? await MailCache.setFlags({ $0.isRead = isRead }, for: changing)   // the next sync corrects any failure
        }
        if problem != nil {
            for message in changing {
                updateLocally(message) { $0.isRead = message.isRead }   // `message` still holds how it was
            }
            changeUnreadCount(of: folder, by: -unreadChange)
        }
    }

    // Flags or unflags messages, on screen straight away, then on the server (put
    // back if the server refuses). Clearing a flag also clears its follow-up date and reminder.
    func setFlagged(_ isFlagged: Bool, for selected: [MailMessage], in folder: MailFolder) async {
        guard let account = account(for: folder), !selected.isEmpty else { return }
        for message in selected {
            updateLocally(message) { $0.isFlagged = isFlagged }
        }
        let problem = await reportingErrors(isFlagged ? "Flagging…" : "Clearing flags…", server: account.imapHost) {
            try await IMAPService.setFlag(.flagged, to: isFlagged, uids: selected.map(\.uid), in: folder.path, account: account)
            if !isFlagged { forgetFollowUps(of: selected) }
            try? await MailCache.setFlags({ $0.isFlagged = isFlagged }, for: selected)   // the next sync corrects any failure
        }
        if problem != nil {
            for message in selected {
                updateLocally(message) { $0.isFlagged = message.isFlagged }
            }
        }
    }

    // MARK: - Categories (see Categories)

    // Adds a color category to messages, or (with `isOn: false`) takes it off,
    // on the server and on screen.
    func setCategory(_ category: MailCategory, isOn: Bool, for selected: [MailMessage], in folder: MailFolder) async {
        await changeCategories([category], isOn: isOn, for: selected, in: folder)
    }

    // Categorize → Clear All Categories.
    func clearCategories(of selected: [MailMessage], in folder: MailFolder) async {
        let used = Set(selected.flatMap(\.categories))
        await changeCategories(Array(used), isOn: false, for: selected, in: folder)
    }

    private func changeCategories(_ categories: [MailCategory], isOn: Bool, for selected: [MailMessage], in folder: MailFolder) async {
        guard let account = account(for: folder), !categories.isEmpty, !selected.isEmpty else { return }
        // `formUnion` adds them to a message's set; `subtract` takes them out.
        let change: @Sendable (inout Set<MailCategory>) -> Void = { isOn ? $0.formUnion(categories) : $0.subtract(categories) }
        // On screen straight away, then the server (put back if the server refuses).
        for message in selected {
            updateLocally(message) { change(&$0.categories) }
        }
        let problem = await reportingErrors("Categorizing…", server: account.imapHost) {
            try await IMAPService.setCategories(categories, to: isOn, uids: selected.map(\.uid), in: folder.path, account: account)
            try? await MailCache.setFlags({ change(&$0.categories) }, for: selected)   // the next sync corrects any failure
        }
        if problem != nil {
            for message in selected {
                updateLocally(message) { $0.categories = message.categories }
            }
        }
    }

    // MARK: - Follow Up (see FollowUp)

    // Due dates of flagged emails, by FollowUps.key.
    private(set) var followUps: [String: FollowUp] = FollowUps.load()

    // A flagged message's follow-up, if it has one.
    func followUp(for message: MailMessage) -> FollowUp? {
        message.isFlagged ? followUps[FollowUps.key(for: message)] : nil
    }

    // Follow Up → Today, Tomorrow…: flags the messages (on the server, like Flag)
    // and gives them that due date and reminder (No Date: just the flag).
    func setFollowUp(_ choice: FollowUpChoice, for selected: [MailMessage], in folder: MailFolder) async {
        let unflagged = selected.filter { !$0.isFlagged }
        if !unflagged.isEmpty {
            await setFlagged(true, for: unflagged, in: folder)
        }
        let followUp = choice.followUp()
        for message in selected {
            followUps[FollowUps.key(for: message)] = followUp
            if let followUp {
                FollowUps.scheduleReminder(for: followUp, message: message)
            } else {
                FollowUps.cancelReminder(for: message)
            }
        }
        FollowUps.save(followUps)
    }

    // Removes messages' due dates and reminders (their flag was cleared, or they were deleted).
    private func forgetFollowUps(of messages: [MailMessage]) {
        let keys = messages.map { FollowUps.key(for: $0) }
        guard keys.contains(where: { followUps[$0] != nil }) else { return }
        for message in messages {
            followUps[FollowUps.key(for: message)] = nil
            FollowUps.cancelReminder(for: message)
        }
        FollowUps.save(followUps)
    }

    // Moves messages to the account's Trash folder, or erases them for good if
    // they're already in Trash (ContentView asks you to confirm that first).
    // Returns what's needed to undo a move to Trash (erasing can't be undone).
    @discardableResult
    func deleteMessages(_ selected: [MailMessage], in folder: MailFolder) async -> CompletedMove? {
        guard let account = account(for: folder), !selected.isEmpty else { return nil }
        forgetFollowUps(of: selected)   // no reminders about deleted mail
        if folder.role == .trash {
            // Off the screen first, then the server (see moveMessages).
            await removeLocally(selected, from: folder)
            let problem = await reportingErrors("Deleting…", server: account.imapHost) {
                try await IMAPService.deletePermanently(uids: selected.map(\.uid), in: folder.path, account: account)
            }
            if let problem { await bringBackMessages(in: folder, after: problem) }
            return nil
        } else if let trash = self.folder(.trash, in: account) {
            return await moveMessages(selected, from: folder, to: trash)
        } else {
            statusText = "Error: This account doesn't have a Trash folder."
            return nil
        }
    }

    // Moves messages to another folder, in the same account or another one (see
    // moveToOtherAccount). Returns what's needed to undo the move, or nil if it
    // failed, the server didn't say where they went, or it was to another account.
    @discardableResult
    func moveMessages(_ selected: [MailMessage], from folder: MailFolder, to destination: MailFolder) async -> CompletedMove? {
        guard let account = account(for: folder), !selected.isEmpty, destination.id != folder.id else { return nil }
        guard destination.accountID == folder.accountID else {
            await moveToOtherAccount(selected, from: folder, to: destination)
            return nil
        }
        var completedMove: CompletedMove?
        let unreadCount = selected.filter { !$0.isRead }.count
        // Take them off the screen straight away, rather than after the server answers
        // (which can take a few seconds, longer if it's busy syncing). This is called
        // an "optimistic" update: assume the server will agree, and put things right
        // in the rare case it doesn't.
        await removeLocally(selected, from: folder)
        changeUnreadCount(of: destination, by: unreadCount)
        let problem = await reportingErrors("Moving to \(destination.displayName)…", server: account.imapHost) {
            let newUIDs = try await IMAPService.moveMessages(uids: selected.map(\.uid), from: folder.path, to: destination.path, account: account)
            if let newUIDs, !newUIDs.isEmpty {
                completedMove = CompletedMove(from: folder, to: destination, newUIDs: newUIDs, unreadCount: unreadCount)
            }
        }
        if let problem {
            changeUnreadCount(of: destination, by: -unreadCount)
            await bringBackMessages(in: folder, after: problem)
        }
        return completedMove
    }

    // After a move or delete the server refused: syncing the folder with the server
    // puts back the messages that were taken off the screen (they're still there).
    // The sync's own "Ready" would hide the error, so it's shown again afterwards.
    private func bringBackMessages(in folder: MailFolder, after problem: String) async {
        await waitForSyncToFinish(of: folder)
        await sync(folder)
        statusText = "Error: \(problem)"
    }

    // Moves messages into a folder of a different account. Servers can't do that
    // themselves, so each message is downloaded whole (with its attachments) and
    // uploaded into the other account, one at a time. Then the originals go to
    // the first account's Trash, rather than being erased, so nothing is lost if
    // something went wrong. (From Trash itself, or an account without one, they're
    // erased.) If one message fails, the ones before it still count as moved.
    private func moveToOtherAccount(_ selected: [MailMessage], from folder: MailFolder, to destination: MailFolder) async {
        guard let sourceAccount = account(for: folder), let destinationAccount = account(for: destination) else { return }
        await reportingErrors("Moving to \(destination.displayName)…", server: destinationAccount.imapHost) {
            var copied: [MailMessage] = []
            var copyError: Error?
            for (index, message) in selected.enumerated() {
                statusText = "Moving \(index + 1) of \(selected.count) to \(destination.displayName)…"
                do {
                    let raw = try await IMAPService.fetchRawMessage(uid: message.uid, in: folder.path, account: sourceAccount)
                    // SwiftMail uploads text, so the message must be readable as UTF-8 (true for
                    // nearly all email). Copying one that isn't could garble it, so refuse instead.
                    guard let rawText = String(data: raw, encoding: .utf8) else {
                        throw MailError(message: "“\(message.subject)” couldn't be moved: it's stored in an older text format that can't be copied between accounts safely.")
                    }
                    var flags: [Flag] = []
                    if message.isRead { flags.append(.seen) }
                    if message.isFlagged { flags.append(.flagged) }
                    flags += message.categories.map { .custom($0.keyword) }   // its color categories go with it
                    try await IMAPService.uploadRawMessage(rawText, to: destination.path, flags: flags,
                                                           date: message.dateReceived == .distantPast ? nil : message.dateReceived,
                                                           account: destinationAccount)
                    copied.append(message)
                } catch {
                    copyError = error
                    break
                }
            }

            // Take the copied originals out of the first account.
            if !copied.isEmpty {
                let uids = copied.map(\.uid)
                if folder.role != .trash, let trash = self.folder(.trash, in: sourceAccount) {
                    try await IMAPService.moveMessages(uids: uids, from: folder.path, to: trash.path, account: sourceAccount)
                    changeUnreadCount(of: trash, by: copied.filter { !$0.isRead }.count)
                } else {
                    try await IMAPService.deletePermanently(uids: uids, in: folder.path, account: sourceAccount)
                }
                await removeLocally(copied, from: folder)
                changeUnreadCount(of: destination, by: copied.filter { !$0.isRead }.count)
            }
            if let copyError { throw copyError }
        }
    }

    // Edit → Undo after a move or delete: moves the messages back to the folder
    // they came from, then updates both folders' saved copies so they show up there again.
    func undo(_ move: CompletedMove) async {
        guard let account = account(for: move.to) else { return }
        let problem = await reportingErrors("Undoing…", server: account.imapHost) {
            try await IMAPService.moveMessages(uids: move.newUIDs, from: move.to.path, to: move.from.path, account: account)
            changeUnreadCount(of: move.to, by: -move.unreadCount)
            changeUnreadCount(of: move.from, by: move.unreadCount)
        }
        guard problem == nil else { return }
        await sync(move.from)
        await sync(move.to)
    }

    // MARK: - Sending (with Undo Send)

    // How long a sent email waits before it really goes, so you can still take it back.
    static let undoSendDelay: TimeInterval = 10

    // Emails waiting out that delay (the status bar shows the newest, with Undo).
    private(set) var pendingSends: [PendingSend] = []
    // Emails taken back with Undo, or that failed to send, for the main window to
    // reopen in compose windows (only views can open windows).
    var draftsToReopen: [ComposeDraft] = []
    // A clicked new-mail notification's email, for the main window to show.
    var mailToShow: MailToShow?

    // The Send button: checks the email can be sent (an account, valid addresses),
    // then starts the wait. Throws straight away if it can't, so the compose
    // window can stay open and show why.
    func queueSend(_ draft: ComposeDraft) throws {
        let account = try sendingAccount(for: draft)
        _ = try makeEmail(from: draft, account: account)   // only to check the addresses now

        let pending = PendingSend(draft: draft, sendsAt: Date().addingTimeInterval(Self.undoSendDelay))
        pendingSends.append(pending)
        pending.timer = Task {
            try? await Task.sleep(for: .seconds(Self.undoSendDelay))
            guard !Task.isCancelled else { return }   // Undo was clicked
            await sendNow(pending)
        }
    }

    // Undo Send: stops the email and hands it back to be reopened.
    func undoSend(_ pending: PendingSend) {
        // If it's no longer waiting, it's already being sent: too late.
        guard pendingSends.contains(where: { $0.id == pending.id }) else { return }
        pending.timer?.cancel()
        pendingSends.removeAll { $0.id == pending.id }
        var draft = pending.draft
        draft.isReopened = true
        draftsToReopen.append(draft)
    }

    // Sends every waiting email straight away (used when quitting). Returns
    // whether they all went; any that failed are waiting to be reopened.
    func sendPendingNow() async -> Bool {
        for pending in pendingSends {
            pending.timer?.cancel()
            await sendNow(pending)
        }
        return draftsToReopen.isEmpty
    }

    // Sends a waiting email. If it fails, the email is reopened with the reason.
    private func sendNow(_ pending: PendingSend) async {
        guard pendingSends.contains(where: { $0.id == pending.id }) else { return }
        pendingSends.removeAll { $0.id == pending.id }
        do {
            try await send(pending.draft)
        } catch {
            reopenAfterFailedSend(pending.draft, error: error)
        }
    }

    // Puts an email that couldn't be sent back in a compose window, saying why.
    private func reopenAfterFailedSend(_ failed: ComposeDraft, error: Error) {
        let account = try? sendingAccount(for: failed)
        statusText = "Error: Couldn't send “\(failed.subject)”."
        var draft = failed
        draft.isReopened = true
        draft.sendError = "Couldn't send: \(FriendlyError.message(for: error, server: account?.smtpHost))"
        draftsToReopen.append(draft)
    }

    // Sends an email right now. Throws if it couldn't be sent.
    private func send(_ draft: ComposeDraft) async throws {
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

    // MARK: - Send Later (see Outbox)

    // Emails waiting in the Outbox, soonest first.
    private(set) var scheduledEmails: [ScheduledEmail] = Outbox.load()

    // Send Later: checks the email can be sent (an account, valid addresses), then
    // puts it in the Outbox. Throws straight away if it can't, so the compose
    // window can stay open and show why.
    func scheduleSend(_ draft: ComposeDraft, at sendAt: Date) throws {
        let account = try sendingAccount(for: draft)
        _ = try makeEmail(from: draft, account: account)   // only to check the addresses now
        scheduledEmails.append(try Outbox.add(draft, sendAt: sendAt))
        scheduledEmails.sort { $0.sendAt < $1.sendAt }
        statusText = "“\(draft.subject)” will be sent \(sendAt.formatted(date: .abbreviated, time: .shortened))"
    }

    // Outbox → Edit: takes the email out of the Outbox and reopens it in a compose
    // window, where it can be sent or scheduled again.
    func editScheduled(_ scheduled: ScheduledEmail) {
        guard scheduledEmails.contains(scheduled) else { return }
        scheduledEmails.removeAll { $0.id == scheduled.id }
        Outbox.remove(scheduled, keepingAttachments: true)   // the compose window attaches the copies
        var draft = scheduled.draft
        draft.isReopened = true   // so closing it without sending asks to save it
        draftsToReopen.append(draft)
    }

    // Outbox → Delete: the email is thrown away without being sent.
    func deleteScheduled(_ scheduled: ScheduledEmail) {
        scheduledEmails.removeAll { $0.id == scheduled.id }
        Outbox.remove(scheduled)
    }

    // Outbox → Send Now.
    func sendScheduledNow(_ scheduled: ScheduledEmail) async {
        _ = await sendScheduled(scheduled)
    }

    // Sends the Outbox emails whose time has come. ContentView runs this every 30
    // seconds, starting at launch, so emails that came due while the app was
    // closed (or the Mac was asleep) go out then, and the status bar says so.
    func sendDueScheduledEmails() async {
        let due = scheduledEmails.filter { scheduled in
            // Wait until its account's folders are known (just after launch they
            // may not be yet), so the Sent copy and the old draft are dealt with properly.
            scheduled.sendAt <= Date() && scheduled.draft.accountID.flatMap { foldersByAccount[$0] } != nil
        }
        var sentLate = 0
        for scheduled in due {
            // "Late" means it went out over two minutes after its time.
            if await sendScheduled(scheduled), Date().timeIntervalSince(scheduled.sendAt) > 2 * 60 {
                sentLate += 1
            }
        }
        if sentLate > 0 {
            statusText = sentLate == 1
                ? "Sent 1 scheduled email that was due while Mailroom Classic was closed or the Mac was asleep."
                : "Sent \(sentLate) scheduled emails that were due while Mailroom Classic was closed or the Mac was asleep."
        }
    }

    // Sends one Outbox email and removes it from the Outbox. If it fails, it's
    // reopened in a compose window with the reason, like a failed Send.
    // Returns whether it was sent.
    private func sendScheduled(_ scheduled: ScheduledEmail) async -> Bool {
        // Edited or deleted meanwhile? Then it's no longer waiting.
        guard scheduledEmails.contains(scheduled) else { return false }
        scheduledEmails.removeAll { $0.id == scheduled.id }   // so it can't be sent twice
        do {
            try await send(scheduled.draft)
            Outbox.remove(scheduled)
            return true
        } catch {
            Outbox.remove(scheduled, keepingAttachments: true)   // the compose window attaches the copies
            reopenAfterFailedSend(scheduled.draft, error: error)
            return false
        }
    }

    // MARK: - Rules

    func addRule(_ rule: MailRule) {
        rules.append(rule)
        RuleStorage.saveRules(rules)
    }

    // Replaces a rule with an edited version of it (same `id`).
    func updateRule(_ rule: MailRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        RuleStorage.saveRules(rules)
    }

    func removeRule(_ rule: MailRule) {
        rules.removeAll { $0.id == rule.id }
        RuleStorage.saveRules(rules)
    }

    // Settings → Rules → Run Rules Now: applies the rules to everything already
    // in each Inbox (the saved last 12 months), not just newly arrived mail.
    func runRulesNow() async {
        for inbox in allFolders where inbox.role == .inbox {
            guard let saved = try? await MailCache.messages(inFolders: [inbox.id]) else { continue }
            await applyRules(to: saved, in: inbox)
        }
    }

    // Does what each rule says (move, mark as read, flag or delete) to the Inbox
    // messages that match it. Each message follows the first rule it matches.
    // Move rules only apply in their folder's own account, and are skipped if
    // that folder no longer exists; the other actions apply in every account.
    private func applyRules(to inboxMessages: [MailMessage], in inbox: MailFolder) async {
        var remaining = inboxMessages
        for rule in rules {
            let matching = remaining.filter { rule.matches($0) }
            guard !matching.isEmpty else { continue }
            switch rule.action {
            case .move:
                guard let destination = allFolders.first(where: { $0.id == rule.destinationFolderID }),
                      destination.accountID == inbox.accountID, destination.id != inbox.id else { continue }
                await moveMessages(matching, from: inbox, to: destination)
            case .markRead:
                await setRead(true, for: matching, in: inbox)
            case .flag:
                let unflagged = matching.filter { !$0.isFlagged }
                if !unflagged.isEmpty { await setFlagged(true, for: unflagged, in: inbox) }
            case .delete:
                await deleteMessages(matching, in: inbox)
            }
            let handledIDs = Set(matching.map(\.id))
            remaining.removeAll { handledIDs.contains($0.id) }
        }
    }

    // MARK: - Managing folders

    // Creates a folder called `name` inside `parent`, or at the top of the account
    // if `parent` is nil, then shows the updated folder list.
    func createFolder(named name: String, inAccount accountID: UUID, inside parent: MailFolder?) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let path = parent?.childPath(named: name) ?? name
        await reportingErrors("Creating “\(name)”…", server: account.imapHost) {
            try await IMAPService.createFolder(path: path, account: account)
            try await reloadFolderList(for: account)
        }
    }

    // Renames a folder (keeping it in the same parent folder). Returns the renamed
    // folder's new ID so the sidebar can keep it selected, or nil if it failed.
    func renameFolder(_ folder: MailFolder, to name: String) async -> MailFolder.ID? {
        guard let account = account(for: folder) else { return nil }
        let newPath = folder.renamedPath(to: name)
        let newID = MailFolder.id(accountID: account.id, path: newPath)
        let problem = await reportingErrors("Renaming “\(folder.displayName)”…", server: account.imapHost) {
            try await IMAPService.renameFolder(from: folder.path, to: newPath, account: account)
            try await reloadFolderList(for: account)
            // Its unread count moves with it (the next check recounts anyway).
            if let index = foldersByAccount[account.id]?.firstIndex(where: { $0.id == newID }) {
                foldersByAccount[account.id]?[index].unreadCount = folder.unreadCount
            }
        }
        return problem == nil ? newID : nil
    }

    // Deletes a folder from the server. Returns whether it worked.
    func deleteFolder(_ folder: MailFolder) async -> Bool {
        guard let account = account(for: folder) else { return false }
        let problem = await reportingErrors("Deleting “\(folder.displayName)”…", server: account.imapHost) {
            try await IMAPService.deleteFolder(path: folder.path, account: account)
            try await reloadFolderList(for: account)
        }
        return problem == nil
    }

    // Permanently erases every message in a folder (Empty Trash / Empty Junk).
    func emptyFolder(_ folder: MailFolder) async {
        guard let account = account(for: folder) else { return }
        await reportingErrors("Emptying \(folder.displayName)…", server: account.imapHost) {
            let uids = try await IMAPService.fetchAllUIDs(in: folder.path, onlyUnread: false, account: account)
            if !uids.isEmpty {
                try await IMAPService.deletePermanently(uids: uids, in: folder.path, account: account)
            }
            try? await MailCache.removeMessages(inFolder: folder.id)   // the next sync corrects any failure
            messages.removeAll { $0.folderID == folder.id }
            olderMessages.removeAll { $0.folderID == folder.id }
            olderRemainingByFolder[folder.id] = 0
            setUnreadCount(of: folder, to: 0)
        }
    }

    // Marks every message in a folder as read, including ones not saved on this Mac.
    func markAllRead(in folder: MailFolder) async {
        guard let account = account(for: folder) else { return }
        await reportingErrors("Marking all as read in \(folder.displayName)…", server: account.imapHost) {
            let unreadUIDs = try await IMAPService.fetchAllUIDs(in: folder.path, onlyUnread: true, account: account)
            if !unreadUIDs.isEmpty {
                try await IMAPService.setFlag(.seen, to: true, uids: unreadUIDs, in: folder.path, account: account)
            }
            try? await MailCache.markAllRead(inFolder: folder.id)   // the next sync corrects any failure
            for index in messages.indices where messages[index].folderID == folder.id {
                messages[index].isRead = true
            }
            for index in olderMessages.indices where olderMessages[index].folderID == folder.id {
                olderMessages[index].isRead = true
            }
            setUnreadCount(of: folder, to: 0)
        }
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

    private func setUnreadCount(of folder: MailFolder, to count: Int) {
        if let index = foldersByAccount[folder.accountID]?.firstIndex(where: { $0.id == folder.id }) {
            foldersByAccount[folder.accountID]?[index].unreadCount = count
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

// A move (or a delete into Trash) that can be undone: where the messages came
// from, where they went, and the new IDs they got there.
struct CompletedMove {
    let from: MailFolder
    let to: MailFolder
    let newUIDs: [UInt32]
    let unreadCount: Int   // how many were unread, to put the unread counts back
}

// An email waiting out the Undo Send delay. A class (not a struct) so the
// waiting timer can be attached after it's made.
final class PendingSend: Identifiable {
    let id = UUID()
    let draft: ComposeDraft
    let sendsAt: Date
    var timer: Task<Void, Never>?   // the wait; cancelling it stops the send

    init(draft: ComposeDraft, sendsAt: Date) {
        self.draft = draft
        self.sendsAt = sendsAt
    }
}

// The email (or, for a "3 new messages" notification, just the folder) that a
// clicked notification asks the main window to show.
struct MailToShow: Equatable {
    let folderID: MailFolder.ID
    let messageID: MailMessage.ID?
}
