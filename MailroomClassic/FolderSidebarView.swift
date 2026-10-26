// The left pane: "All Inboxes" at the top, then every account with its folders
// listed underneath, like the folder tree in classic Outlook. Clicking a folder
// selects it, and dropping dragged messages onto a folder moves them there.

import SwiftUI

struct FolderSidebarView: View {
    @Environment(MailStore.self) private var store

    // `@Binding` means this view doesn't own the selection; it reads and
    // changes a value that belongs to its parent (ContentView).
    @Binding var selectedFolderID: MailFolder.ID?

    // Called when messages are dropped on a folder. Returns whether the drop was accepted.
    let dropMessages: (_ messageIDs: [MailMessage.ID], _ destination: MailFolder) -> Bool

    var body: some View {
        List(selection: $selectedFolderID) {
            if !store.accounts.isEmpty {
                // Every account's Inbox in one list. Its badge is the total unread.
                Label("All Inboxes", systemImage: "tray.2")
                    .badge(store.unreadInboxCount)
                    .tag(MailFolder.allInboxesID)
            }
            ForEach(store.accounts) { account in
                Section(account.emailAddress) {
                    ForEach(store.foldersByAccount[account.id] ?? []) { folder in
                        Label(folder.displayName, systemImage: folder.role.iconName)
                            .badge(folder.unreadCount)   // a count of 0 shows no badge
                            .tag(folder.id)              // what gets stored when this row is selected
                            // Accept messages dragged from the message list.
                            .dropDestination(for: String.self) { items, _ in
                                guard let messageIDs = items.first.flatMap({ MessageDrag.parse($0) }) else { return false }
                                return dropMessages(messageIDs, folder)
                            }
                    }
                }
            }
        }
    }
}
