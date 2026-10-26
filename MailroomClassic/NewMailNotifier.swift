// Lets you know about new mail: a Mac notification ("New mail from Sarah:
// Dinner?") when Mailroom Classic isn't the app in front, and the unread
// count as a red badge on the Dock icon.

import AppKit
import UserNotifications

enum NewMailNotifier {
    // The Settings checkbox is stored under this name (on unless you turn it off).
    static let settingKey = "notifyNewMail"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    // Asks macOS for permission to show notifications. macOS only asks you once;
    // after that this does nothing (you can change it in System Settings → Notifications).
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Shows one notification per new message, or a summary if several arrived at once.
    static func announce(_ messages: [MailMessage], account: AccountSettings) {
        guard isEnabled, !messages.isEmpty, !NSApp.isActive else { return }   // no alerts while you're using the app

        let content = UNMutableNotificationContent()
        content.subtitle = account.displayName
        content.sound = .default
        if messages.count == 1, let message = messages.first {
            content.title = "New mail from \(message.sender.name ?? message.sender.address)"
            content.body = message.subject
        } else {
            content.title = "\(messages.count) new messages"
            content.body = messages.prefix(3).map { $0.sender.name ?? $0.sender.address }.joined(separator: ", ")
        }
        // `trigger: nil` means "show it now".
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Puts the unread count on the Dock icon, or removes the badge at zero.
    static func updateDockBadge(unreadCount: Int) {
        NSApp.dockTile.badgeLabel = unreadCount > 0 ? "\(unreadCount)" : nil
    }
}
