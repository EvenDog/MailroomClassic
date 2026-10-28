// Follow Up: a flag with a due date (Today, Tomorrow, This Week, Next Week, or a
// date you pick) and a reminder, like classic Outlook. The flag itself is saved
// on the server, so your phone sees it flagged too, but IMAP has no standard
// place for a due date, so due dates are kept on this Mac only (in the app's
// settings). They're filed under each email's worldwide-unique Message-ID, so a
// due date stays with its email when it moves to another folder. Reminders are
// Mac notifications that macOS shows at 9:00 AM on the due day (or at the
// exact time you picked), even if Mailroom Classic is closed.

import Foundation
import UserNotifications

// When a flagged email is due, and when to remind you (nil: no reminder).
struct FollowUp: Codable, Equatable {
    var dueDate: Date
    var remindAt: Date?
}

// The choices in the Follow Up menus.
enum FollowUpChoice: Hashable {
    case today, tomorrow, thisWeek, nextWeek
    case noDate     // just a flag
    case pickDate   // asks for a date and time first, which then comes back as `at`
    case at(Date)

    // The choices listed in the menus, before "Choose Date & Time…".
    static let quickChoices: [FollowUpChoice] = [.today, .tomorrow, .thisWeek, .nextWeek, .noDate]

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .thisWeek: "This Week (Friday)"
        case .nextWeek: "Next Week (Monday)"
        case .noDate: "No Date"
        case .pickDate, .at: "Choose Date & Time…"
        }
    }

    // What this choice means if chosen at `now`, or nil for just a flag.
    func followUp(from now: Date = Date(), calendar: Calendar = .current) -> FollowUp? {
        let today = calendar.startOfDay(for: now)
        let dueDay: Date
        switch self {
        case .noDate, .pickDate:
            return nil
        case .at(let time):
            return FollowUp(dueDate: calendar.startOfDay(for: time), remindAt: time)
        case .today:
            dueDay = today
        case .tomorrow:
            dueDay = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case .thisWeek, .nextWeek:
            // The next Friday (today, if it's Friday) or the next Monday after today.
            // In Apple's calendar, weekday 2 is Monday and 6 is Friday.
            let weekday = self == .thisWeek ? 6 : 2
            let searchFrom = self == .thisWeek ? today.addingTimeInterval(-1) : today
            dueDay = calendar.nextDate(after: searchFrom, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? today
        }
        // Remind at 9:00 AM on the due day, unless that's already past.
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dueDay)
        return FollowUp(dueDate: dueDay, remindAt: nineAM.flatMap { $0 > now ? $0 : nil })
    }
}

enum FollowUps {
    private static let storageKey = "followUps"

    // The name a message's follow-up is filed under: its Message-ID, or (for the
    // rare email without one) its place in its folder.
    static func key(for message: MailMessage) -> String {
        message.messageID ?? message.id
    }

    // Every saved follow-up, by key.
    static func load() -> [String: FollowUp] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: FollowUp].self, from: data) else { return [:] }
        return saved
    }

    static func save(_ followUps: [String: FollowUp]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(followUps), forKey: storageKey)
    }

    // e.g. "Due Today", "Due Tomorrow", "Due Fri, Oct 30".
    static func dueText(for dueDate: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(dueDate, inSameDayAs: now) { return "Due Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(dueDate, inSameDayAs: tomorrow) {
            return "Due Tomorrow"
        }
        return "Due " + dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // Due today or earlier, so shown in red.
    static func isDueNow(_ dueDate: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        dueDate < calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    // MARK: Reminders

    // Reminder notifications' names start with this, so AppDelegate can tell them
    // from new-mail ones. (`nonisolated`: AppDelegate checks it from a background thread.)
    nonisolated static let reminderPrefix = "followup-"

    // Asks macOS to show a reminder at the follow-up's reminder time (replacing any
    // earlier one for the same email). Clicking it opens the email (see AppDelegate).
    static func scheduleReminder(for followUp: FollowUp, message: MailMessage) {
        cancelReminder(for: message)
        guard let remindAt = followUp.remindAt, remindAt > Date() else { return }
        // In case notifications were never allowed (they're asked for at launch only
        // when new-mail notifications are on). macOS only asks once.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = "Follow up: \(message.subject)"
        content.body = "From \(message.senderDisplayName)"
        content.sound = .default
        content.userInfo = [NewMailNotifier.folderIDKey: message.folderID, NewMailNotifier.messageIDKey: message.id]
        // A calendar trigger fires once, when the clock reaches this date and time.
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: remindAt)
        let request = UNNotificationRequest(identifier: reminderPrefix + key(for: message), content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    static func cancelReminder(for message: MailMessage) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderPrefix + key(for: message)])
    }
}
