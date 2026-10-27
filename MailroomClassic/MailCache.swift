// The local copy of your mail: a database file on this Mac holding each account's
// folder list, the headers (sender, subject, date, read/flagged…) of the last
// 12 months of messages in every folder, and the contents of messages you've
// opened, like classic Outlook's offline file. The message list reads
// from here, so folders open instantly; MailSync keeps it matching the server.
// It uses GRDB, a Swift library on top of SQLite (the database engine built
// into macOS). A "table" is like a spreadsheet: one row per saved item.

import Foundation
import GRDB
import SwiftMail   // for MessagePart, inside a saved MessageBody

// How far back the local copy reaches. Older mail stays on the server and can
// still be found with search or "Show Older Messages".
enum OfflineWindow {
    static let months = 12

    static var startDate: Date {
        Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
    }
}

// A message's read and flagged status: the part of a message that can change
// on the server after we've saved it (e.g. you read it on your phone).
nonisolated struct MessageFlags: Equatable, Sendable {
    var isRead: Bool
    var isFlagged: Bool
}

// What we've saved for one folder: its numbering ID (see MailSync) and the
// status of every saved message, by UID.
nonisolated struct SavedFolder: Sendable {
    var uidValidity: UInt32
    var flags: [UInt32: MessageFlags]
}

enum MailCache {
    // The database, opened the first time it's used.
    static let database: DatabaseQueue = {
        do {
            return try openDatabaseFile()
        } catch {
            // The file couldn't be opened (e.g. the disk is full). Fall back to a
            // database held only in memory: everything still works, but nothing
            // is kept between launches. Creating an empty in-memory database
            // doesn't touch the disk, so the `try!` (crash if it fails) is safe here.
            return try! DatabaseQueue()
        }
    }()

    // Opens (or creates) ~/Library/Application Support/MailroomClassic/MailCache.sqlite
    // and brings its tables up to date.
    private static func openDatabaseFile() throws -> DatabaseQueue {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MailroomClassic", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: folder.appendingPathComponent("MailCache.sqlite").path)
        try migrator.migrate(database)
        return database
    }

    // "Migrations" are numbered steps that build the tables. A new version of
    // the app that needs a different layout adds a new step ("v2"), and GRDB
    // runs only the steps a given Mac hasn't run yet. Never edit an old step.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: StoredMessage.databaseTableName) { table in
                table.column("folderID", .text).notNull()
                table.column("uid", .integer).notNull()
                table.column("sender", .text).notNull()          // addresses are saved as JSON text
                table.column("replyTo", .text).notNull()
                table.column("toRecipients", .text).notNull()
                table.column("ccRecipients", .text).notNull()
                table.column("subject", .text).notNull()
                table.column("dateReceived", .datetime).notNull()
                table.column("messageID", .text)
                table.column("referenceIDs", .text).notNull()
                table.column("hasAttachments", .boolean).notNull()
                table.column("isRead", .boolean).notNull()
                table.column("isFlagged", .boolean).notNull()
                table.primaryKey(["folderID", "uid"])            // one row per message per folder
            }
            // An "index" makes "this folder's messages, newest first" fast to look up.
            try db.create(index: "message_by_folder_and_date", on: StoredMessage.databaseTableName,
                          columns: ["folderID", "dateReceived"])
            try db.create(table: StoredFolderState.databaseTableName) { table in
                table.primaryKey("folderID", .text)
                table.column("uidValidity", .integer).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            // Each account's folder list, so the sidebar can appear at launch before
            // (or without) connecting. One row per account; the folders are JSON text.
            try db.create(table: StoredFolderList.databaseTableName) { table in
                table.primaryKey("accountID", .text)
                table.column("folders", .text).notNull()
            }
        }
        migrator.registerMigration("v3") { db in
            // The contents of messages you've opened, so opening them again is instant.
            try db.create(table: StoredBody.databaseTableName) { table in
                table.column("folderID", .text).notNull()
                table.column("uid", .integer).notNull()
                table.column("plainText", .text).notNull()
                table.column("html", .text)
                table.column("attachmentParts", .text).notNull()   // JSON, like the addresses
                table.primaryKey(["folderID", "uid"])
                // A "foreign key": each body belongs to a row in the message table. With
                // `.cascade`, deleting that message (moved, deleted, or now older than 12
                // months) makes SQLite delete its body too, so nothing is left behind.
                table.foreignKey(["folderID", "uid"], references: StoredMessage.databaseTableName,
                                 columns: ["folderID", "uid"], onDelete: .cascade)
            }
        }
        return migrator
    }

    // MARK: - Reading

    // The saved messages in these folders, newest first.
    static func messages(inFolders folderIDs: [MailFolder.ID]) async throws -> [MailMessage] {
        try await database.read { db in
            try StoredMessage
                .filter(folderIDs.contains(Column("folderID")))
                .order(Column("dateReceived").desc)
                .fetchAll(db)
                .map(\.mailMessage)
        }
    }

    // Saved messages in these folders whose subject, sender or recipients
    // (name or address) contain `query`, ignoring letter case; newest first.
    static func search(_ query: String, inFolders folderIDs: [MailFolder.ID]) async throws -> [MailMessage] {
        // In LIKE, % means "anything" and _ means "any one character". Put a \ before any
        // the query contains, so they're matched as ordinary characters.
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        // Addresses are stored as JSON, so json_extract / json_each look inside them.
        let matches = """
            subject LIKE :pattern ESCAPE '\\'
            OR json_extract(sender, '$.name') LIKE :pattern ESCAPE '\\'
            OR json_extract(sender, '$.address') LIKE :pattern ESCAPE '\\'
            OR EXISTS (SELECT 1 FROM json_each(toRecipients) WHERE json_extract(value, '$.name') LIKE :pattern ESCAPE '\\'
                       OR json_extract(value, '$.address') LIKE :pattern ESCAPE '\\')
            OR EXISTS (SELECT 1 FROM json_each(ccRecipients) WHERE json_extract(value, '$.name') LIKE :pattern ESCAPE '\\'
                       OR json_extract(value, '$.address') LIKE :pattern ESCAPE '\\')
            """
        return try await database.read { db in
            try StoredMessage
                .filter(folderIDs.contains(Column("folderID")))
                .filter(sql: matches, arguments: ["pattern": "%\(escaped)%"])
                .order(Column("dateReceived").desc)
                .fetchAll(db)
                .map(\.mailMessage)
        }
    }

    // Every account's folder list from the last time it was checked, by account ID.
    static func folderLists() async throws -> [UUID: [MailFolder]] {
        try await database.read { db in
            var lists: [UUID: [MailFolder]] = [:]
            for row in try StoredFolderList.fetchAll(db) {
                if let accountID = UUID(uuidString: row.accountID) { lists[accountID] = row.folders }
            }
            return lists
        }
    }

    // When the newest saved message in a folder arrived, or nil if none are saved.
    static func newestDate(inFolder folderID: MailFolder.ID) async throws -> Date? {
        try await database.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(dateReceived) FROM message WHERE folderID = ?", arguments: [folderID])
        }
    }

    // The saved contents of a message you've opened before, or nil.
    static func body(of message: MailMessage) async throws -> MessageBody? {
        let folderID = message.folderID, uid = Int64(message.uid)
        return try await database.read { db in
            try StoredBody.fetchOne(db, key: ["folderID": folderID, "uid": uid])?.body
        }
    }

    // The messages in a folder whose contents aren't saved yet, newest first
    // (for downloading ahead of time).
    static func messagesWithoutBody(inFolder folderID: MailFolder.ID) async throws -> [MailMessage] {
        try await database.read { db in
            // A "LEFT JOIN" pairs each message with its body row if there is one;
            // `messageBody.uid IS NULL` keeps the ones that have none.
            try StoredMessage.fetchAll(db, sql: """
                SELECT message.* FROM message
                LEFT JOIN messageBody ON messageBody.folderID = message.folderID AND messageBody.uid = message.uid
                WHERE message.folderID = ? AND messageBody.uid IS NULL
                ORDER BY message.dateReceived DESC
                """, arguments: [folderID])
                .map(\.mailMessage)
        }
    }

    // What's saved for a folder, or nil if it's never been synced.
    static func savedFolder(_ folderID: MailFolder.ID) async throws -> SavedFolder? {
        try await database.read { db in
            guard let state = try StoredFolderState.fetchOne(db, key: folderID) else { return nil }
            var flags: [UInt32: MessageFlags] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT uid, isRead, isFlagged FROM message WHERE folderID = ?",
                                        arguments: [folderID])
            for row in rows {
                flags[UInt32(row["uid"] as Int64)] = MessageFlags(isRead: row["isRead"], isFlagged: row["isFlagged"])
            }
            return SavedFolder(uidValidity: UInt32(state.uidValidity), flags: flags)
        }
    }

    // MARK: - Writing

    // Makes a folder's saved copy match a sync plan (everything except
    // downloading new messages, which `save` does as they arrive).
    static func apply(_ plan: FolderSyncPlan, to folderID: MailFolder.ID, uidValidity: UInt32) async throws {
        try await database.write { db in
            if plan.startOver {
                try StoredMessage.filter(Column("folderID") == folderID).deleteAll(db)
            }
            if !plan.removedUIDs.isEmpty {
                try StoredMessage
                    .filter(Column("folderID") == folderID && plan.removedUIDs.map(Int64.init).contains(Column("uid")))
                    .deleteAll(db)
            }
            for (uid, flags) in plan.changedFlags {
                try db.execute(sql: "UPDATE message SET isRead = ?, isFlagged = ? WHERE folderID = ? AND uid = ?",
                               arguments: [flags.isRead, flags.isFlagged, folderID, Int64(uid)])
            }
            try StoredFolderState(folderID: folderID, uidValidity: Int64(uidValidity)).upsert(db)
        }
    }

    // Saves an account's folder list, replacing the last one.
    static func saveFolderList(_ folders: [MailFolder], for accountID: UUID) async throws {
        let row = StoredFolderList(accountID: accountID.uuidString, folders: folders)
        try await database.write { db in
            try row.upsert(db)
        }
    }

    // Saves an opened message's contents. Fails if the message itself isn't saved
    // (e.g. one fetched with Show Older Messages), which is fine: those aren't kept.
    static func saveBody(_ body: MessageBody, for message: MailMessage) async throws {
        let row = StoredBody(folderID: message.folderID, uid: Int64(message.uid), body: body)
        try await database.write { db in
            try row.upsert(db)
        }
    }

    // Saves several messages' contents at once. Any whose message was removed in the
    // meantime (moved, deleted) are skipped instead of failing the rest.
    static func saveBodies(_ bodies: [(message: MailMessage, body: MessageBody)]) async throws {
        let rows = bodies.map { StoredBody(folderID: $0.message.folderID, uid: Int64($0.message.uid), body: $0.body) }
        try await database.write { db in
            for row in rows {
                try? row.upsert(db)   // fails only if its message is gone
            }
        }
    }

    // Saves messages, replacing any already saved with the same folder and UID.
    static func save(_ messages: [MailMessage]) async throws {
        let rows = messages.map(StoredMessage.init)
        try await database.write { db in
            for row in rows {
                try row.upsert(db)
            }
        }
    }

    // Records a read/flag change you made in this app.
    static func setFlags(_ change: @escaping @Sendable (inout MessageFlags) -> Void, for messages: [MailMessage]) async throws {
        let keys = messages.map { (folderID: $0.folderID, uid: Int64($0.uid), flags: MessageFlags(isRead: $0.isRead, isFlagged: $0.isFlagged)) }
        try await database.write { db in
            for key in keys {
                var flags = key.flags
                change(&flags)
                try db.execute(sql: "UPDATE message SET isRead = ?, isFlagged = ? WHERE folderID = ? AND uid = ?",
                               arguments: [flags.isRead, flags.isFlagged, key.folderID, key.uid])
            }
        }
    }

    // Records that every message in a folder is read (after Mark All as Read).
    static func markAllRead(inFolder folderID: MailFolder.ID) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE message SET isRead = 1 WHERE folderID = ?", arguments: [folderID])
        }
    }

    // Forgets every message in a folder (after Empty Trash / Empty Junk).
    static func removeMessages(inFolder folderID: MailFolder.ID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM message WHERE folderID = ?", arguments: [folderID])
        }
    }

    // Forgets messages that were moved or deleted in this app.
    static func remove(_ messages: [MailMessage]) async throws {
        let keys = messages.map { (folderID: $0.folderID, uid: Int64($0.uid)) }
        try await database.write { db in
            for key in keys {
                try db.execute(sql: "DELETE FROM message WHERE folderID = ? AND uid = ?", arguments: [key.folderID, key.uid])
            }
        }
    }

    // Forgets everything saved for an account's folders, except `keeping`
    // (pass the folders the server still has, to drop deleted or renamed ones;
    // pass nothing to forget the whole account).
    static func forgetFolders(ofAccount accountID: UUID, keeping folderIDs: [MailFolder.ID] = []) async throws {
        // Folder IDs start with the account's ID and a "/", e.g. "1A2B…/INBOX".
        let prefix = "\(accountID)/%"
        try await database.write { db in
            for table in [StoredMessage.databaseTableName, StoredFolderState.databaseTableName] {
                let placeholders = Array(repeating: "?", count: folderIDs.count).joined(separator: ",")
                let keepClause = folderIDs.isEmpty ? "" : " AND folderID NOT IN (\(placeholders))"
                try db.execute(sql: "DELETE FROM \(table) WHERE folderID LIKE ?\(keepClause)",
                               arguments: StatementArguments([prefix] + folderIDs))
            }
            if folderIDs.isEmpty {   // forgetting the whole account: its folder list too
                _ = try StoredFolderList.deleteOne(db, key: accountID.uuidString)
            }
        }
    }
}

// One saved message header: a row in the "message" table. `Codable` lets GRDB
// turn it into a row and back; lists of addresses are stored as JSON text.
// `nonisolated` means it isn't tied to the main thread, since GRDB reads and
// writes rows on its own background thread.
nonisolated struct StoredMessage: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "message"

    var folderID: String
    var uid: Int64   // SQLite stores whole numbers as 64-bit
    var sender: MailAddress
    var replyTo: [MailAddress]
    var toRecipients: [MailAddress]
    var ccRecipients: [MailAddress]
    var subject: String
    var dateReceived: Date
    var messageID: String?
    var referenceIDs: [String]
    var hasAttachments: Bool
    var isRead: Bool
    var isFlagged: Bool

    init(_ message: MailMessage) {
        folderID = message.folderID
        uid = Int64(message.uid)
        sender = message.sender
        replyTo = message.replyTo
        toRecipients = message.toRecipients
        ccRecipients = message.ccRecipients
        subject = message.subject
        dateReceived = message.dateReceived
        messageID = message.messageID
        referenceIDs = message.references
        hasAttachments = message.hasAttachments
        isRead = message.isRead
        isFlagged = message.isFlagged
    }

    var mailMessage: MailMessage {
        MailMessage(uid: UInt32(uid), folderID: folderID, sender: sender, replyTo: replyTo,
                    toRecipients: toRecipients, ccRecipients: ccRecipients, subject: subject,
                    dateReceived: dateReceived, messageID: messageID, references: referenceIDs,
                    hasAttachments: hasAttachments, isRead: isRead, isFlagged: isFlagged)
    }
}

// One row per synced folder in the "folderState" table.
nonisolated struct StoredFolderState: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "folderState"

    var folderID: String
    var uidValidity: Int64
}

// One row per account in the "folderList" table.
nonisolated struct StoredFolderList: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "folderList"

    var accountID: String
    var folders: [MailFolder]
}

// One opened message's contents: a row in the "messageBody" table.
nonisolated struct StoredBody: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "messageBody"

    var folderID: String
    var uid: Int64
    var plainText: String
    var html: String?
    var attachmentParts: [MessagePart]

    init(folderID: String, uid: Int64, body: MessageBody) {
        self.folderID = folderID
        self.uid = uid
        plainText = body.plainText
        html = body.html
        attachmentParts = body.attachmentParts
    }

    var body: MessageBody {
        MessageBody(plainText: plainText, html: html, attachmentParts: attachmentParts)
    }
}
