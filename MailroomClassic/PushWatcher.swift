// Push mail: new mail shows up within seconds instead of at the next check.
// For each account, this keeps a few extra connections open, one per watched
// folder (Inbox, Sent and Drafts), each waiting with IMAP's IDLE command, which
// means "I'm listening: tell me as soon as something changes here". When the
// server says a message arrived or was removed, MailStore updates that folder.
// The regular check (every few minutes) still runs too, for the other folders
// and in case a connection quietly stops working.

import Foundation
import SwiftMail

final class PushWatcher {
    // The Settings checkbox is stored under this name (on unless you turn it off).
    static let settingKey = "pushNewMail"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    // The folders watched in each account.
    static let watchedRoles: [FolderRole] = [.inbox, .sent, .drafts]

    // The work that keeps the connections open; cancelling it closes them.
    private var task: Task<Void, Never>?

    // Starts watching `folders` straight away. `onChange` is called (about two
    // seconds after the first sign of a change, so a burst of new emails
    // causes one update, not one each) with the folder that changed.
    init(account: AccountSettings, folders: [MailFolder], onChange: @escaping @MainActor (MailFolder) async -> Void) {
        task = Task {
            await Self.watch(folders, of: account, onChange: onChange)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // How the connections recover when they drop (e.g. the Wi-Fi went away):
    // SwiftMail reconnects by itself, first after 30 seconds, then waiting twice
    // as long after each failure, up to 15 minutes. That's gentler than its
    // defaults (1 second, up to 2 minutes), because Gmail slows down accounts
    // that log in too often.
    private static var reconnectSettings: IMAPIdleConfiguration {
        var settings = IMAPIdleConfiguration.default
        settings.reconnectBaseDelay = 30
        settings.reconnectMaxDelay = 15 * 60
        return settings
    }

    // Logs in, opens a watching connection per folder, and passes on their news
    // until cancelled. If logging in fails, tries again later. Office 365's sign-in
    // token only lasts about an hour, so for Office 365 this starts over (with a
    // fresh token) every 50 minutes.
    private static func watch(_ folders: [MailFolder], of account: AccountSettings,
                              onChange: @escaping @MainActor (MailFolder) async -> Void) async {
        while !Task.isCancelled {
            var server: IMAPServer?
            var sessions: [(folder: MailFolder, session: IMAPIdleSession)] = []
            var waitBeforeTryingAgain = false
            do {
                try LoginBackoff.checkAllowed(for: account)   // throws while waiting after failed logins
                let loggedIn: IMAPServer
                do {
                    loggedIn = try await IMAPService.connectAndLogIn(account)
                } catch {
                    if !(error is CancellationError) { LoginBackoff.recordFailure(for: account) }
                    throw error
                }
                server = loggedIn
                LoginBackoff.recordSuccess(for: account)
                // A server that can't IDLE can't push; the regular check still works.
                guard try await loggedIn.fetchCapabilities().contains(.idle) else {
                    try? await loggedIn.disconnect()
                    return
                }
                for folder in folders {
                    // Each `idle(on:)` opens its own connection with the folder open.
                    sessions.append((folder, try await loggedIn.idle(on: folder.path, configuration: reconnectSettings)))
                }

                // A task group runs several pieces of work at once: one per folder,
                // each reading that folder's news, plus (for Office 365) a timer.
                // `group.next()` waits for the first piece to finish, which normally
                // only happens when the timer runs out (it returns true) or all of
                // this is being stopped.
                let isPlannedRestart = await withTaskGroup(of: Bool.self) { group in
                    for (folder, session) in sessions {
                        group.addTask {
                            // `for await` handles each piece of news as it arrives.
                            for await event in session.events where isChange(event) {
                                await noticeChange(in: folder, onChange: onChange)
                            }
                            return false
                        }
                    }
                    if account.provider == .office365 {
                        group.addTask {
                            try? await Task.sleep(for: .seconds(50 * 60))
                            return true
                        }
                    }
                    let first = await group.next()
                    group.cancelAll()
                    return first == true
                }
                // A connection that ended by itself: don't rush to log in again.
                waitBeforeTryingAgain = !isPlannedRestart
            } catch {
                waitBeforeTryingAgain = true
            }
            // Close everything (also any connections opened before a failure). In a
            // separate `Task`, because this one may be being stopped, and work in a
            // stopped task can end early; a new Task isn't stopped, so it finishes.
            await Task { [sessions, server] in
                for (_, session) in sessions {
                    try? await session.done()
                }
                try? await server?.disconnect()
            }.value
            if waitBeforeTryingAgain {
                try? await Task.sleep(for: .seconds(5 * 60))   // ends early if this is being stopped
            }
        }
    }

    // News that means the folder's list of messages changed: mail arrived
    // (`exists`, the new message count) or was removed (`expunge`, `vanished`).
    // Read/flag changes are left to the regular check: every message you click
    // would cause one, and refreshing for each would mean a lot of requests.
    // (`nonisolated`: it only looks at the event, so background work may call it.)
    nonisolated private static func isChange(_ event: IMAPServerEvent) -> Bool {
        switch event {
        case .exists, .expunge, .vanished: true
        default: false
        }
    }

    // Folders with an update already waiting to start, so more news about the
    // same folder in the meantime doesn't start a second one.
    private static var foldersWaitingForUpdate: Set<MailFolder.ID> = []

    private static func noticeChange(in folder: MailFolder, onChange: @escaping @MainActor (MailFolder) async -> Void) {
        guard !foldersWaitingForUpdate.contains(folder.id) else { return }
        foldersWaitingForUpdate.insert(folder.id)
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Removed before updating, so news arriving during the update starts another one.
            foldersWaitingForUpdate.remove(folder.id)
            await onChange(folder)
        }
    }
}
