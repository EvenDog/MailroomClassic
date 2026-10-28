// Send Later: emails waiting to be sent at a time you chose, like classic
// Outlook's Outbox. Mail servers can't hold an email and send it later, so
// they wait on this Mac and Mailroom Classic sends them when the time comes
// (or as soon as it's next open, if it was closed then). Each one is saved in
// ~/Library/Application Support/MailroomClassic/Outbox/, in its own folder holding
// the email (email.json) and copies of its attachments, so attachments from
// temporary places (like a forwarded email's) are still there when it's sent.

import Foundation

// One email waiting in the Outbox.
struct ScheduledEmail: Codable, Identifiable, Equatable {
    var id = UUID()
    var draft: ComposeDraft
    var sendAt: Date
}

enum Outbox {
    // The Outbox folder, created if it doesn't exist yet.
    private static var folder: URL {
        get throws {
            let folder = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MailroomClassic/Outbox", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    }

    private static func emailFile(in emailFolder: URL) -> URL {
        emailFolder.appendingPathComponent("email.json")
    }

    // Every scheduled email, soonest first. Ones that can't be read are skipped.
    static func load() -> [ScheduledEmail] {
        guard let emailFolders = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return emailFolders
            .compactMap { try? JSONDecoder().decode(ScheduledEmail.self, from: Data(contentsOf: emailFile(in: $0))) }
            .sorted { $0.sendAt < $1.sendAt }
    }

    // Saves a new scheduled email, copying its attachments into its own folder.
    // Returns it as saved (its attachments pointing at the copies).
    static func add(_ draft: ComposeDraft, sendAt: Date) throws -> ScheduledEmail {
        var scheduled = ScheduledEmail(draft: draft, sendAt: sendAt)
        let emailFolder = try folder.appendingPathComponent(scheduled.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: emailFolder, withIntermediateDirectories: true)
        do {
            // Each attachment gets a numbered subfolder, so two files with the same name can't collide.
            scheduled.draft.attachmentURLs = try draft.attachmentURLs.enumerated().map { number, original in
                let copyFolder = emailFolder.appendingPathComponent("\(number)", isDirectory: true)
                try FileManager.default.createDirectory(at: copyFolder, withIntermediateDirectories: true)
                let copy = copyFolder.appendingPathComponent(original.lastPathComponent)
                try FileManager.default.copyItem(at: original, to: copy)
                return copy
            }
            try JSONEncoder().encode(scheduled).write(to: emailFile(in: emailFolder))
        } catch {
            try? FileManager.default.removeItem(at: emailFolder)   // don't leave half of it behind
            throw error
        }
        return scheduled
    }

    // Takes an email out of the Outbox. With `keepingAttachments`, only the email
    // itself is removed, because a compose window is about to use the attachment copies.
    static func remove(_ scheduled: ScheduledEmail, keepingAttachments: Bool = false) {
        guard let emailFolder = try? folder.appendingPathComponent(scheduled.id.uuidString, isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: keepingAttachments ? emailFile(in: emailFolder) : emailFolder)
    }
}

// The quick choices in the compose window's Send Later menu.
enum SendLaterChoice: CaseIterable {
    case inOneHour, tomorrowMorning, mondayMorning

    var title: String {
        switch self {
        case .inOneHour: "In 1 Hour"
        case .tomorrowMorning: "Tomorrow Morning (8:00 AM)"
        case .mondayMorning: "Monday Morning (8:00 AM)"
        }
    }

    // When the email would be sent if chosen at `now`.
    func sendTime(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .inOneHour:
            return now.addingTimeInterval(60 * 60)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .mondayMorning:
            // The next Monday at 8:00 (a week away if today is Monday). In Apple's calendar, weekday 2 is Monday.
            let monday = DateComponents(hour: 8, minute: 0, weekday: 2)
            return calendar.nextDate(after: now, matching: monday, matchingPolicy: .nextTime) ?? now
        }
    }
}
