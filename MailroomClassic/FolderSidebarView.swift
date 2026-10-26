// The left pane: every account, with its folders listed underneath, like the
// folder tree in classic Outlook. Clicking a folder selects it.

import SwiftUI

struct FolderSidebarView: View {
    @Environment(MailStore.self) private var store

    // `@Binding` means this view doesn't own the selection; it reads and
    // changes a value that belongs to its parent (ContentView).
    @Binding var selectedFolderID: MailFolder.ID?

    var body: some View {
        List(selection: $selectedFolderID) {
            ForEach(store.accounts) { account in
                Section(account.emailAddress) {
                    ForEach(store.foldersByAccount[account.id] ?? []) { folder in
                        Label(folder.displayName, systemImage: folder.role.iconName)
                            .badge(folder.unreadCount)   // a count of 0 shows no badge
                            .tag(folder.id)              // what gets stored when this row is selected
                    }
                }
            }
        }
    }
}
