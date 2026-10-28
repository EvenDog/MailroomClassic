// The starting point of Mailroom Classic. When the app launches, macOS runs
// this code first: it creates the shared MailStore and sets up the app's
// windows: the main mail window, compose windows, message windows, and Settings.
// It also asks before quitting if any email hasn't been sent, sends any email
// still waiting out its Undo Send delay before it quits, and opens the email
// when you click a new-mail notification.

import AppKit
import SwiftUI
import UserNotifications

// `@main` marks this as the app's entry point: the one place execution begins.
@main
struct MailroomClassicApp: App {
    @State private var store = MailStore()
    // Connects AppDelegate (below), for the "unsent emails" question when quitting.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Window` (rather than `WindowGroup`) means there's only ever one main window.
        Window("Mailroom Classic", id: "main") {
            ContentView()
                .environment(store)   // hands the store to this view and everything inside it
                .onAppear { appDelegate.store = store }   // so quitting can send waiting emails
        }
        .defaultSize(width: 1200, height: 750)   // size of the window the first time it opens
        // Email links (mailto:) clicked in other apps come to this window, which
        // opens a compose window for them (see ContentView's `.onOpenURL`).
        .handlesExternalEvents(matching: ["mailto"])
        .commands {
            // Replace File → New Window with File → New Email (⌘N).
            CommandGroup(replacing: .newItem) {
                NewEmailMenuItem()
            }
            // File → Print… (⌘P) prints the open message.
            CommandGroup(replacing: .printItem) {
                PrintMenuItem()
            }
            // View → Reading Pane → Right / Bottom, and View → Preview Text.
            CommandGroup(after: .sidebar) {
                ReadingPaneMenu()
                MessageListMenu()
                PreviewTextMenuItem()
                ConversationsMenuItem()
            }
            // Adds the standard Format menu: Bold ⌘B, Italic ⌘I, Underline ⌘U, Show Fonts ⌘T, Show Colors.
            TextFormattingCommands()
        }

        // Compose windows. Each one is opened with a ComposeDraft (blank, or a pre-filled reply).
        WindowGroup("New Message", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft ?? ComposeDraft())
                .environment(store)
        }
        .defaultSize(width: 700, height: 560)
        .handlesExternalEvents(matching: [])   // never open a blank one for an email link

        // A message in its own window (double-click it in the list). It's opened
        // with the message's ID; the window looks the message up itself.
        WindowGroup("Message", id: "message", for: MailMessage.ID.self) { $messageID in
            if let messageID {
                MessageWindowView(messageID: messageID)
                    .environment(store)
            }
        }
        .defaultSize(width: 800, height: 650)
        .handlesExternalEvents(matching: [])
        // Don't reopen message windows at the next launch: the message may be gone by then.
        .restorationBehavior(.disabled)

        // Settings (⌘,) has two tabs, like most Mac apps' settings windows.
        Settings {
            TabView {
                AccountsSettingsView()
                    .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                RulesSettingsView()
                    .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            }
            .environment(store)
        }
    }
}

// The File → New Email menu item. It's a separate view because opening a
// window needs `openWindow`, which only views can read from the environment.
private struct NewEmailMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Email") {
            openWindow(id: "compose", value: ComposeDraft())
        }
        .keyboardShortcut("n")   // ⌘N
    }
}

// A "focused value" lets a window offer something to the menu bar while that
// window is in front. The main window offers its print action this way.
// `@Entry` is shorthand that writes the boilerplate for a new focused value.
extension FocusedValues {
    @Entry var printMessage: PrintAction?
}

// The print action, labelled with the message it prints. SwiftUI can't compare
// two functions, so it compares the message IDs instead to tell if anything changed.
struct PrintAction: Equatable {
    let messageID: MailMessage.ID
    let run: () -> Void

    static func == (first: PrintAction, second: PrintAction) -> Bool {
        first.messageID == second.messageID
    }
}

// File → Print…: prints the open message, or is greyed out if there isn't one.
private struct PrintMenuItem: View {
    @FocusedValue(\.printMessage) private var printMessage

    var body: some View {
        Button("Print…") { printMessage?.run() }
            .keyboardShortcut("p")   // ⌘P
            .disabled(printMessage == nil)
    }
}

// View → Reading Pane: a submenu with a checkmark next to the current choice.
private struct ReadingPaneMenu: View {
    @AppStorage("readingPaneAtBottom") private var readingPaneAtBottom = false

    var body: some View {
        Picker("Reading Pane", selection: $readingPaneAtBottom) {
            Text("Right").tag(false)
            Text("Bottom").tag(true)
        }
    }
}

// Settings → Accounts → Appearance: whether the app is light, dark, follows
// the Mac's own setting (System Settings → Appearance), or uses one of the
// in-between themes: Dim (soft blue-grey), Dusk (warm charcoal) or Mist (muted light grey).
enum AppAppearance: String, CaseIterable {
    case system = "Match System"
    case light = "Light"
    case dark = "Dark"
    case dim = "Dim"
    case dusk = "Dusk"
    case mist = "Mist"

    static let storageKey = "appearance"

    // The saved choice (Match System until one is picked).
    static var saved: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    // Applies it to every window at once. `NSApp.appearance` is the app-wide
    // setting from AppKit (the Mac's older interface toolkit, under SwiftUI);
    // "aqua" is macOS's name for the light look, "darkAqua" for the dark one,
    // and nil means follow the Mac. The in-between themes sit on top of one of
    // those (so buttons, menus and text colors match) and paint their own
    // backgrounds; see `colors`.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light, .mist: NSAppearance(named: .aqua)
        case .dark, .dim, .dusk: NSAppearance(named: .darkAqua)
        }
    }

    // The backgrounds an in-between theme paints, or nil to leave macOS's own.
    var colors: ThemeColors? {
        switch self {
        case .system, .light, .dark: nil
        case .dim: ThemeColors(sidebar: Color(hex: 0x252A32), list: Color(hex: 0x2C313A), reading: Color(hex: 0x313742))
        case .dusk: ThemeColors(sidebar: Color(hex: 0x2C2926), list: Color(hex: 0x34302C), reading: Color(hex: 0x39352F))
        case .mist: ThemeColors(sidebar: Color(hex: 0xD3D7DC), list: Color(hex: 0xE4E7EA), reading: Color(hex: 0xEEF0F2))
        }
    }
}

// An in-between theme's background colors: the folder sidebar, the message
// list, and the reading pane (also used by message windows).
struct ThemeColors {
    let sidebar: Color
    let list: Color
    let reading: Color
}

extension Color {
    // A color from a hex number like web colors, e.g. Color(hex: 0x2C313A).
    // `>> 16` and `& 0xFF` pick out the red, green and blue parts (0–255 each).
    init(hex: Int) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    // Paints a theme's background behind a list (hiding the list's own), or
    // leaves the view as macOS draws it when `color` is nil.
    @ViewBuilder
    func themeBackground(_ color: Color?) -> some View {
        if let color {
            self.scrollContentBackground(.hidden).background(color)
        } else {
            self
        }
    }
}

// View → Message List: Comfortable (two-line rows) or Compact (one-line rows in
// columns), the same choice as the switch above the message list.
private struct MessageListMenu: View {
    @AppStorage(MessageListDensity.storageKey) private var density = MessageListDensity.comfortable

    var body: some View {
        Picker("Message List", selection: $density) {
            ForEach(MessageListDensity.allCases, id: \.self) { density in
                Text(density.rawValue)
            }
        }
    }
}

// View → Preview Text: shows or hides the start of each message's text after its
// subject in the message list (classic Outlook called this AutoPreview).
// A Toggle in a menu shows as an item with a checkmark when it's on.
private struct PreviewTextMenuItem: View {
    @AppStorage("showPreviewText") private var showPreviewText = true

    var body: some View {
        Toggle("Preview Text", isOn: $showPreviewText)
    }
}

// View → Show as Conversations: groups each email with its replies in the message
// list (see Conversations). Off at first, like classic Outlook.
private struct ConversationsMenuItem: View {
    @AppStorage("showConversations") private var showConversations = false

    var body: some View {
        Toggle("Show as Conversations", isOn: $showConversations)
    }
}

// The app's "delegate": the object macOS asks about app-wide events.
// Here it's asked whether the app may quit (⌘Q), and told when a notification is clicked.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var store: MailStore?   // set by the main window when it appears

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self   // so clicks on notifications come here
        AppAppearance.saved.apply()   // Light, Dark or Match System, from Settings
    }

    // A new-mail notification was clicked: ask the main window to show that email.
    // `nonisolated` because macOS calls this from a background thread; `Task { @MainActor … }`
    // then hops over to the main thread, where the app's data lives.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let details = response.notification.request.content.userInfo
        let folderID = details[NewMailNotifier.folderIDKey] as? String
        let messageID = details[NewMailNotifier.messageIDKey] as? String
        Task { @MainActor in
            if let folderID {
                self.store?.mailToShow = MailToShow(folderID: folderID, messageID: messageID)
            }
            NSApp.activate()
        }
        completionHandler()
    }

    // A notification is due while this app is in front. macOS hides those unless
    // told otherwise: show follow-up reminders anyway (new-mail notifications are
    // only sent while the app is in the background, so they don't come here).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isReminder = notification.request.identifier.hasPrefix(FollowUps.reminderPrefix)
        completionHandler(isReminder ? [.banner, .list, .sound] : [])
    }

    // If any compose window has unsent changes, asks first. Compose windows
    // with changes are marked "edited" by WindowCloseGuard (the dot in their
    // close button), so those are the ones to look for. Then sends any email
    // still waiting for its Undo Send delay to pass.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard confirmQuitWithScheduledEmails() else { return .terminateCancel }
        let unsent = sender.windows.filter { $0.isVisible && $0.isDocumentEdited }
        guard !unsent.isEmpty else { return sendWaitingEmailsThenQuit(sender) }

        let alert = NSAlert()
        alert.messageText = unsent.count == 1
            ? "You have an email you haven't sent."
            : "You have \(unsent.count) emails you haven't sent."
        alert.informativeText = "Do you want to review before quitting? If you quit anyway, unsaved changes are lost."
        alert.addButton(withTitle: "Review…")   // the first button is the default (Return)
        alert.addButton(withTitle: "Cancel")
        let quitButton = alert.addButton(withTitle: "Quit Anyway")
        quitButton.hasDestructiveAction = true  // shown in red

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Each window asks its own "Do you want to save changes?" question.
            for window in unsent {
                window.makeKeyAndOrderFront(nil)
                window.performClose(nil)
            }
            return .terminateCancel
        case .alertThirdButtonReturn:
            return sendWaitingEmailsThenQuit(sender)
        default:
            return .terminateCancel
        }
    }

    // Emails in the Outbox are only sent while the app is open, so say so before
    // quitting. Returns whether to go ahead and quit.
    private func confirmQuitWithScheduledEmails() -> Bool {
        guard let count = store?.scheduledEmails.count, count > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "1 email is waiting in the Outbox."
            : "\(count) emails are waiting in the Outbox."
        alert.informativeText = "Scheduled emails are only sent while Mailroom Classic is open. If you quit, any that come due go out the next time you open it."
        alert.addButton(withTitle: "Quit")     // the first button is the default (Return)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // You clicked Send on these, so they go now rather than being lost.
    // `.terminateLater` tells macOS "wait, I'll answer soon"; `reply(...)` is
    // that answer: quit if they all went, or stay open to show any that failed.
    private func sendWaitingEmailsThenQuit(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, !store.pendingSends.isEmpty else { return .terminateNow }
        Task {
            let allSent = await store.sendPendingNow()
            sender.reply(toApplicationShouldTerminate: allSent)
        }
        return .terminateLater
    }
}
