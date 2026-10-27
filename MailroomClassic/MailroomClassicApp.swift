// The starting point of Mailroom Classic. When the app launches, macOS runs
// this code first: it creates the shared MailStore and sets up the app's
// windows: the main mail window, compose windows, and Settings. It also asks
// before quitting if any email hasn't been sent.

import AppKit
import SwiftUI

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
        }
        .defaultSize(width: 1200, height: 750)   // size of the window the first time it opens
        .commands {
            // Replace File → New Window with File → New Email (⌘N).
            CommandGroup(replacing: .newItem) {
                NewEmailMenuItem()
            }
            // File → Print… (⌘P) prints the open message.
            CommandGroup(replacing: .printItem) {
                PrintMenuItem()
            }
            // View → Reading Pane → Right / Bottom.
            CommandGroup(after: .sidebar) {
                ReadingPaneMenu()
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

// The app's "delegate": the object macOS asks about app-wide events.
// Here it's asked whether the app may quit (⌘Q).
final class AppDelegate: NSObject, NSApplicationDelegate {
    // If any compose window has unsent changes, asks first. Compose windows
    // with changes are marked "edited" by WindowCloseGuard (the dot in their
    // close button), so those are the ones to look for.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsent = sender.windows.filter { $0.isVisible && $0.isDocumentEdited }
        guard !unsent.isEmpty else { return .terminateNow }

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
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
