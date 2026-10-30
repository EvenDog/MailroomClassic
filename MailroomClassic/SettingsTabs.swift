// The General, Reading and Categories tabs of the Settings window (⌘,).
// The Accounts tab is in AccountsSettingsView.swift and the Rules tab in RulesSettingsView.swift.
// Every setting here is saved with `@AppStorage`, so the main window picks up changes straight away.

import Sparkle
import SwiftUI

// Settings → General: how the app looks, how it checks for mail, and email links.
struct GeneralSettingsView: View {
    @Environment(MailStore.self) private var store

    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @AppStorage(PushWatcher.settingKey) private var pushNewMail = true
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 5
    @AppStorage(NewMailNotifier.settingKey) private var notifyNewMail = true
    @AppStorage(MailStore.undoSendDelayKey) private var undoSendDelaySeconds = 10

    @State private var isDefaultEmailApp = DefaultEmailApp.isThisApp
    @State private var defaultAppError: String?

    // The updater (see Updater.swift). Sparkle saves its own "check automatically" setting,
    // so the switch starts from Sparkle's value and hands every change back to it.
    private let updater: SPUUpdater
    @State private var checksForUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _checksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                // A pop-up menu: six choices are too many to show side by side.
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { choice in
                        Text(choice.rawValue)
                    }
                }
                .onChange(of: appearance) { appearance.apply() }   // switch every window straight away
                Text("Dim, Dusk and Mist are softer, in-between looks. Emails with their own white background still show white.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Checking for Mail") {
                Toggle("Get new mail instantly (push)", isOn: $pushNewMail)
                    .onChange(of: pushNewMail) { store.restartPush() }   // starts or stops it straight away
                Text("Inbox, Sent and Drafts update within seconds. Other folders update at each check below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Check for new mail", selection: $checkIntervalMinutes) {
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 10 minutes").tag(10)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Manually (Send/Receive only)").tag(0)
                }
                Toggle("Show a notification when new mail arrives", isOn: $notifyNewMail)
            }

            Section("Sending") {
                Picker("Undo Send", selection: $undoSendDelaySeconds) {
                    Text("Off").tag(0)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }
                Text("How long a sent email waits before it really goes. Until then, the bar at the bottom of the main window has an Undo button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) { updater.automaticallyChecksForUpdates = checksForUpdates }
                HStack {
                    // The version number from the app's Info.plist, e.g. "0.5".
                    Text("You have version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?").")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                }
            }

            Section("Email Links") {
                if isDefaultEmailApp {
                    Text("Clicking an email address in another app or a website starts a new email here.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Clicking an email address in another app or a website opens a different app.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Mailroom Classic") {
                            Task {
                                defaultAppError = await DefaultEmailApp.makeThisApp()
                                isDefaultEmailApp = DefaultEmailApp.isThisApp
                            }
                        }
                    }
                }
                if let defaultAppError {
                    Text(defaultAppError)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 680)
        .onChange(of: notifyNewMail) {
            if notifyNewMail { NewMailNotifier.requestPermission() }
        }
    }
}

// Settings → Reading: how the message list and reading pane behave, and which
// senders' pictures always download. The first three are the same settings as
// the View menu's items (they share a saved setting, so both stay in sync).
struct ReadingSettingsView: View {
    @AppStorage("showConversations") private var showConversations = false
    @AppStorage("showPreviewText") private var showPreviewText = true
    @AppStorage("readingPaneAtBottom") private var readingPaneAtBottom = false
    @AppStorage(MailStore.markAsReadDelayKey) private var markAsReadDelaySeconds = 0
    @AppStorage(ContentView.selectNextAfterDeleteKey) private var selectNextAfterDelete = true
    @AppStorage(PictureSenders.storageKey) private var pictureSenders = ""

    @State private var showsPictureSenders = false   // whether the senders list is open
    @State private var pictureSenderSearch = ""      // what's typed in its search box

    var body: some View {
        Form {
            Section("Message List") {
                Toggle("Show as conversations", isOn: $showConversations)
                Text("Groups each email with its replies. Works when the list is sorted by date.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show preview text", isOn: $showPreviewText)
                Picker("Reading pane", selection: $readingPaneAtBottom) {
                    Text("Right").tag(false)
                    Text("Bottom").tag(true)
                }
            }

            Section("Reading") {
                // Like classic Outlook's "Mark items as read when viewed in the Reading Pane: wait N seconds".
                Picker("Mark messages as read", selection: $markAsReadDelaySeconds) {
                    Text("Immediately").tag(0)
                    Text("After 3 seconds").tag(3)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                }
                // Like classic Outlook's "After moving or deleting an open item".
                Picker("After deleting or moving a message", selection: $selectNextAfterDelete) {
                    Text("Select nothing").tag(false)
                    Text("Select the next message").tag(true)
                }
                Text("The next message shows in the reading pane but stays unread until you click in the reading pane.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Always Download Pictures From") {
                // `pictureSenders` is the saved list itself (one address per line), so
                // this section redraws whenever a sender is added or removed.
                let senders = pictureSenders.split(separator: "\n").map(String.init)
                if senders.isEmpty {
                    Text("No senders yet. To add one, click “Always from This Sender” on the pictures bar above a message.")
                        .foregroundStyle(.secondary)
                } else {
                    // A row with an arrow that opens and closes the list. Closed at first, since it can get long.
                    DisclosureGroup("Senders (\(senders.count))", isExpanded: $showsPictureSenders) {
                        TextField("Search", text: $pictureSenderSearch, prompt: Text("Search senders"))
                            .labelsHidden()
                        // Only the senders containing what's typed, ignoring upper/lower case. Empty box = all of them.
                        let matches = pictureSenderSearch.isEmpty
                            ? senders
                            : senders.filter { $0.localizedCaseInsensitiveContains(pictureSenderSearch) }
                        if matches.isEmpty {
                            Text("No senders match “\(pictureSenderSearch)”.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(matches, id: \.self) { address in
                            HStack {
                                Text(address)
                                Spacer()
                                Button("Remove") { PictureSenders.remove(address) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
    }
}

// Settings → Categories: renaming the color categories.
struct CategoriesSettingsView: View {
    var body: some View {
        Form {
            Section("Categories") {
                ForEach(MailCategory.allCases, id: \.self) { category in
                    CategoryNameField(category: category)
                }
                Text("Rename the color categories (Categorize in the toolbar or right-click menu). Names are kept on this Mac; the colors are saved with your mail on the server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 420)
    }
}

// One category's name box in Settings, with its color beside it. Each category's
// name is its own setting, and `@AppStorage` needs to know which one when it's
// created, so each box is its own small view.
private struct CategoryNameField: View {
    let category: MailCategory
    @AppStorage private var name: String

    init(category: MailCategory) {
        self.category = category
        _name = AppStorage(wrappedValue: "", category.nameKey)   // "" means the default name
    }

    var body: some View {
        HStack {
            Circle()
                .fill(category.color)
                .frame(width: 12, height: 12)
            TextField(category.defaultName, text: $name, prompt: Text(category.defaultName))
                .labelsHidden()
        }
    }
}
