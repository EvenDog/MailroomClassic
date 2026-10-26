// Keeps the local copy of each folder (MailCache) matching the server. For one
// folder, a sync:
//   1. asks the server which messages are inside the offline window, and each
//      one's read/flagged status (cheap: just numbers and flags),
//   2. compares that with what's saved (`FolderSyncPlan`): new messages,
//      messages deleted elsewhere, and status changed elsewhere,
//   3. applies the changes, then downloads the new messages' headers in small
//      batches, newest first, saving each batch as it arrives.
// If a sync stops halfway (you quit, the Wi-Fi drops), the next one simply
// picks up whatever is still missing.

import Foundation

// What the server says about one folder right now.
nonisolated struct ServerFolderSnapshot: Sendable {
    // The folder's numbering ID. Message UIDs only mean something together
    // with it: if it ever changes, the server has renumbered the folder, and
    // every saved UID is meaningless (rare, but it happens after server moves).
    var uidValidity: UInt32
    var messageCount: Int               // messages in the whole folder, including older ones
    var flags: [UInt32: MessageFlags]   // every message inside the offline window
}

// What has to change in a folder's saved copy to match the server.
nonisolated struct FolderSyncPlan: Equatable, Sendable {
    var startOver = false                        // renumbered: throw the saved copy away
    var removedUIDs: [UInt32] = []               // gone from the server, or now older than the window
    var changedFlags: [UInt32: MessageFlags] = [:] // read or flagged somewhere else
    var newUIDs: [UInt32] = []                   // not saved yet, newest (highest UID) first

    // Works out the plan by comparing the saved copy with the server.
    init(saved: SavedFolder?, server: ServerFolderSnapshot) {
        startOver = saved != nil && saved?.uidValidity != server.uidValidity
        let savedFlags = startOver ? [:] : saved?.flags ?? [:]

        removedUIDs = savedFlags.keys.filter { server.flags[$0] == nil }.sorted()
        for (uid, serverFlags) in server.flags {
            if let saved = savedFlags[uid] {
                if saved != serverFlags { changedFlags[uid] = serverFlags }
            } else {
                newUIDs.append(uid)
            }
        }
        newUIDs.sort(by: >)
    }
}

enum MailSync {
    // How many headers to download per request. Small batches let other work
    // (like opening a message) get a turn between them.
    static let headerBatchSize = 100

    // Brings one folder's saved copy up to date. `didChange` is called whenever
    // the saved copy changed, so the message list can refresh as messages arrive.
    // Returns how many messages are older than the offline window (only on the server).
    @discardableResult
    static func sync(_ folder: MailFolder, account: AccountSettings, didChange: () async -> Void) async throws -> Int {
        let server = try await IMAPService.fetchSyncSnapshot(of: folder, since: OfflineWindow.startDate, account: account)
        let saved = try await MailCache.savedFolder(folder.id)
        let plan = FolderSyncPlan(saved: saved, server: server)

        try await MailCache.apply(plan, to: folder.id, uidValidity: server.uidValidity)
        if plan.startOver || !plan.removedUIDs.isEmpty || !plan.changedFlags.isEmpty {
            await didChange()
        }

        // Download what's new, newest first, so the top of the list fills in first.
        for start in stride(from: 0, to: plan.newUIDs.count, by: headerBatchSize) {
            try Task.checkCancellation()
            let batch = Array(plan.newUIDs[start ..< min(start + headerBatchSize, plan.newUIDs.count)])
            let messages = try await IMAPService.fetchHeaders(uids: batch, in: folder, account: account)
            try await MailCache.save(messages)
            await didChange()
        }
        return max(0, server.messageCount - server.flags.count)
    }
}
