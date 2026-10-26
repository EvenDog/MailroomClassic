// The left pane: "All Inboxes" at the top, then every account with its folders
// listed underneath, like the folder tree in classic Outlook: folders inside
// other folders (e.g. Jobs → Arrow) are nested, with an arrow to show or hide
// them. Clicking a folder selects it, and dropping dragged messages onto a
// folder moves them there. Each account can be collapsed to hide its folders.

import SwiftUI

struct FolderSidebarView: View {
    @Environment(MailStore.self) private var store

    // `@Binding` means this view doesn't own the selection; it reads and
    // changes a value that belongs to its parent (ContentView).
    @Binding var selectedFolderID: MailFolder.ID?

    // Called when messages are dropped on a folder. Returns whether the drop was accepted.
    let dropMessages: (_ messageIDs: [MailMessage.ID], _ destination: MailFolder) -> Bool

    // The IDs of collapsed accounts, separated by commas. `@AppStorage` saves it
    // in the app's settings, so collapsed accounts stay collapsed next launch.
    @AppStorage("collapsedAccountIDs") private var collapsedAccountIDs = ""

    var body: some View {
        List(selection: $selectedFolderID) {
            if !store.accounts.isEmpty {
                // Every account's Inbox in one list. Its badge is the total unread.
                Label("All Inboxes", systemImage: "tray.2")
                    .badge(store.unreadInboxCount)
                    .tag(MailFolder.allInboxesID)
            }
            ForEach(store.accounts) { account in
                // Hovering over the account's name shows an arrow that collapses or expands it.
                Section(account.emailAddress, isExpanded: isExpanded(account)) {
                    // If the last check of this account failed, say why (it stays until a check works).
                    if let problem = store.accountProblems[account.id] {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(problem)
                    }
                    // OutlineGroup shows a tree: each node's `children` appear nested under it.
                    OutlineGroup(FolderNode.tree(from: store.foldersByAccount[account.id] ?? []), children: \.children) { node in
                        folderRow(node)
                    }
                }
            }
        }
    }

    // Whether an account's folders are showing. A `Binding` is a value plus a way to
    // change it: `get` reads it from collapsedAccountIDs, `set` updates that list.
    private func isExpanded(_ account: AccountSettings) -> Binding<Bool> {
        let id = account.id.uuidString
        return Binding(
            get: { !collapsedAccountIDs.split(separator: ",").contains(Substring(id)) },
            set: { expanded in
                var ids = collapsedAccountIDs.split(separator: ",").map(String.init).filter { $0 != id }
                if !expanded { ids.append(id) }
                collapsedAccountIDs = ids.joined(separator: ",")
            }
        )
    }

    private func folderRow(_ node: FolderNode) -> some View {
        Label(node.name, systemImage: node.folder.role.iconName)
            .badge(node.folder.role.showsUnreadCount ? node.folder.unreadCount : 0)   // a count of 0 shows no badge
            .tag(node.folder.id)              // what gets stored when this row is selected
            // Accept messages dragged from the message list.
            .dropDestination(for: String.self) { items, _ in
                guard let messageIDs = items.first.flatMap({ MessageDrag.parse($0) }) else { return false }
                return dropMessages(messageIDs, node.folder)
            }
    }
}

// One folder in the sidebar's tree, with the folders inside it.
struct FolderNode: Identifiable {
    let folder: MailFolder
    let name: String               // e.g. "Arrow" when it sits inside "Jobs"
    var children: [FolderNode]?    // nil (not empty) for no children, so no arrow is shown

    var id: MailFolder.ID { folder.id }

    // Arranges an account's folders into a tree: "Jobs/Arrow" goes inside "Jobs"
    // when there's a folder called "Jobs"; otherwise it stays at the top level
    // with its full name. Folders keep the order they came in.
    static func tree(from folders: [MailFolder]) -> [FolderNode] {
        let foldersByName = Dictionary(folders.map { ($0.displayName, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenByParentID: [MailFolder.ID: [MailFolder]] = [:]
        var topLevel: [MailFolder] = []
        for folder in folders {
            if let parentName = parentName(of: folder), let parent = foldersByName[parentName], parent.id != folder.id {
                childrenByParentID[parent.id, default: []].append(folder)
            } else {
                topLevel.append(folder)
            }
        }
        // Builds a node and, the same way, nodes for everything inside it.
        // (A function that calls itself like this is "recursive".)
        func node(for folder: MailFolder, isNested: Bool) -> FolderNode {
            let children = childrenByParentID[folder.id]?.map { node(for: $0, isNested: true) }
            return FolderNode(folder: folder, name: isNested ? lastPart(of: folder) : folder.displayName, children: children)
        }
        return topLevel.map { node(for: $0, isNested: false) }
    }

    // "Jobs/Arrow" → "Jobs"; nil for a folder that isn't inside another.
    private static func parentName(of folder: MailFolder) -> String? {
        guard let delimiter = folder.hierarchyDelimiter, !delimiter.isEmpty,
              let range = folder.displayName.range(of: delimiter, options: .backwards) else { return nil }
        return String(folder.displayName[..<range.lowerBound])
    }

    // "Jobs/Arrow" → "Arrow".
    private static func lastPart(of folder: MailFolder) -> String {
        guard let delimiter = folder.hierarchyDelimiter, !delimiter.isEmpty,
              let range = folder.displayName.range(of: delimiter, options: .backwards) else { return folder.displayName }
        return String(folder.displayName[range.upperBound...])
    }
}
