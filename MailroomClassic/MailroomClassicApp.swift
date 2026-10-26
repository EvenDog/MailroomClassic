// The starting point of Mailroom Classic. When the app launches, macOS runs
// this code first: it creates the shared MailStore and sets up the app's
// windows: the main mail window, compose windows, and Settings.

import SwiftUI

// `@main` marks this as the app's entry point: the one place execution begins.
@main
struct MailroomClassicApp: App {
    @State private var store = MailStore()

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
            // Adds the standard Format menu: Bold ⌘B, Italic ⌘I, Underline ⌘U, Show Fonts ⌘T, Show Colors.
            TextFormattingCommands()
        }

        // Compose windows. Each one is opened with a ComposeDraft (blank, or a pre-filled reply).
        WindowGroup("New Message", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft ?? ComposeDraft())
                .environment(store)
        }
        .defaultSize(width: 700, height: 560)

        Settings {
            AccountsSettingsView()
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
