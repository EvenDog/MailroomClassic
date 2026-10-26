// The basic building blocks of the app's data: an email account's settings,
// the folders inside it, and the messages inside each folder. These are plain
// descriptions of data; they don't draw anything or talk to any mail server.

import Foundation

// Which kind of email service an account uses. This decides the server
// addresses, how you log in, and whether the server saves sent mail itself.
// `CaseIterable` lets the Settings picker list every option automatically.
enum MailProvider: String, Codable, CaseIterable, Identifiable {
    case other       // any standard IMAP/SMTP host, e.g. MXroute
    case gmail
    case office365

    var id: Self { self }

    var label: String {
        switch self {
        case .other: "Other (IMAP/SMTP, e.g. MXroute)"
        case .gmail: "Gmail"
        case .office365: "Office 365 / Exchange Online"
        }
    }

    // Gmail and Office 365 put a copy of everything you send into your Sent
    // folder automatically. Other servers don't, so the app saves it there itself.
    var savesSentMailAutomatically: Bool { self != .other }
}

// The connection details for one email account, saved between launches.
// The password (or sign-in token) is deliberately NOT stored here; it lives in the Keychain.
// `Codable` means Swift can convert this to and from JSON text automatically.
struct AccountSettings: Codable, Identifiable, Hashable {
    var id = UUID()            // UUID = a random, unique identifier
    var provider: MailProvider
    var displayName: String    // e.g. "MXroute"
    var senderName: String     // your name, as recipients see it
    var emailAddress: String   // also used as the login username
    var imapHost: String       // incoming mail server, e.g. "xxx.mxrouting.net"
    var imapPort: Int          // 993 is the standard port for secure IMAP
    var smtpHost: String       // outgoing mail server
    var smtpPort: Int          // 465 (secure from the start) or 587 (upgrades to secure)
    var microsoftClientID: String?   // only for Office 365; see README for how to get one
    var signature: String?           // added to the bottom of emails you write, if set
}

// What a folder is for. Decides its icon, its place in the list, and which
// folder Delete moves messages into. `String` gives each case a text name
// ("inbox", "sent"…), which is how it's saved on disk.
enum FolderRole: String, Codable, Hashable {
    case inbox, drafts, sent, trash, junk, archive, other
    case allMail   // Gmail's "All Mail": every message in the account, whatever its labels

    // Guesses the role from a folder's name, for servers that don't label their folders.
    init(name: String) {
        let name = name.lowercased()
        if name == "inbox" { self = .inbox }
        else if name.contains("draft") { self = .drafts }
        else if name.contains("sent") { self = .sent }
        else if name.contains("trash") || name.contains("deleted") || name == "bin" { self = .trash }
        else if name.contains("junk") || name.contains("spam") { self = .junk }
        else if name.contains("archive") { self = .archive }
        else { self = .other }
    }

    var iconName: String {
        switch self {
        case .inbox: "tray"
        case .drafts: "doc"
        case .sent: "paperplane"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .archive: "archivebox"
        case .allMail: "tray.full"
        case .other: "folder"
        }
    }

    // All Mail's unread count includes every unread message in the account, so it isn't useful.
    var showsUnreadCount: Bool { self != .allMail }

    // Classic Outlook order: Inbox, Drafts, Sent, Deleted, Junk, then everything else.
    var sortRank: Int {
        switch self {
        case .inbox: 0
        case .drafts: 1
        case .sent: 2
        case .trash: 3
        case .junk: 4
        case .allMail, .archive, .other: 5
        }
    }
}

// One folder (IMAP calls them "mailboxes") inside an account.
// `Identifiable` means each item has a unique `id`, which SwiftUI uses to keep
// track of rows in lists and to remember which one is selected.
// `Codable` lets the folder list be saved on this Mac (see MailCache).
struct MailFolder: Identifiable, Hashable, Codable {
    let accountID: UUID
    let path: String           // the folder's name on the server, e.g. "INBOX.Sent"
    let displayName: String    // the friendly name we show, e.g. "Sent"
    let role: FolderRole
    var unreadCount: Int
    // The character the server puts between a folder and the folders inside it,
    // e.g. "/" in "Jobs/Arrow". Nil if the server doesn't say.
    var hierarchyDelimiter: String? = nil
    // The ID the server will give the next message that arrives. If it goes up
    // between checks, new mail has arrived. (Nil if the server doesn't say.)
    var uidNext: UInt32?

    // Folder names are only unique within one account, so combine both.
    var id: String { Self.id(accountID: accountID, path: path) }

    static func id(accountID: UUID, path: String) -> String {
        "\(accountID)/\(path)"
    }

    // The sidebar's "All Inboxes" row isn't a real folder, so it gets its own ID.
    // (Real folder IDs always start with an account's UUID, so they can't clash with it.)
    static let allInboxesID = "all-inboxes"
}

// One person's email address, optionally with their name.
struct MailAddress: Hashable, Codable {
    let name: String?
    let address: String

    // "Sarah Miller <sarah@example.com>", or just the address if there's no name.
    // Names with commas or quotes get wrapped in quotes ("Miller, Sarah"), so a
    // list of addresses can still be split apart at the commas between them.
    var formatted: String {
        guard let name, !name.isEmpty else { return address }
        if name.contains(where: { ",;\"".contains($0) }) {
            return "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }
}

// The summary of one email shown in the message list. The full body is
// downloaded separately, only when the message is opened.
struct MailMessage: Identifiable {
    let uid: UInt32            // the server's ID number for this message within its folder
    let folderID: MailFolder.ID   // the folder it's in (All Inboxes mixes messages from several)
    let sender: MailAddress
    let replyTo: [MailAddress] // where replies should go, if different from the sender
    let toRecipients: [MailAddress]
    let ccRecipients: [MailAddress]
    let subject: String
    let dateReceived: Date
    let messageID: String?     // the email's worldwide-unique ID, used to thread replies
    let references: [String]   // IDs of earlier emails in the same conversation
    let hasAttachments: Bool
    var isRead: Bool
    var isFlagged: Bool

    // A UID is only unique inside one folder, so the ID includes the folder too.
    var id: String { "\(folderID)#\(uid)" }

    // The sender's name, or their address if there's no name. Shown in the
    // From column, and what that column sorts by.
    var senderDisplayName: String { sender.name ?? sender.address }
}

// The full contents of the message open in the reading pane.
struct OpenMessage {
    let plainText: String      // always present; used for quoting in replies and for plain emails
    let html: String?          // the formatted version, if the email has one
    let attachments: [MailAttachment]
}

// One file attached to a received email. The file itself isn't downloaded
// until you open, save or forward it, so big attachments don't slow down reading.
struct MailAttachment: Identifiable {
    let id = UUID()
    let filename: String
    let mimeType: String       // the file's type, e.g. "application/pdf"
    let approximateSize: Int?  // in bytes, as reported by the server before downloading
    // Fetches the file from the server. It's a function stored in a property:
    // the mail code fills it in, and calling `try await attachment.download()` runs it.
    // `@Sendable` means it's safe to call from background work.
    let download: @Sendable () async throws -> Data

    // e.g. "1.2 MB", or nil if the server didn't say.
    var sizeText: String? {
        approximateSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }
}


// A simple error with a readable message, for problems the app detects itself.
struct MailError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
