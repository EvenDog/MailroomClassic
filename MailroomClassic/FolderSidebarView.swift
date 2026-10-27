// The left pane: "All Inboxes" at the top, then every account with its folders
// listed underneath, like the folder tree in classic Outlook: folders inside
// other folders (e.g. Jobs → Arrow) are nested, with an arrow to show or hide
// them. Clicking a folder selects it, and dropping dragged messages onto a
// folder moves them there. Each account can be collapsed to hide its folders,
// and everything except Inbox, Drafts, Sent, Trash and Junk sits in a
// collapsible "More Folders" group.
// Right-click a folder for New/Rename/Delete Folder, Mark All as Read and
// Empty Trash/Junk; right-click an account's name to make a top-level folder.

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
    // The IDs of accounts whose "More Folders" group is open (it starts closed), in the same format.
    @AppStorage("accountsShowingMoreFolders") private var accountsShowingMoreFolders = ""

    // The folder name box (for New Folder and Rename Folder): what it's for, and what's typed.
    @State private var nameRequest: FolderNameRequest?
    @State private var isAskingForName = false
    @State private var typedFolderName = ""
    // The folder waiting for you to confirm Delete Folder or Empty.
    @State private var folderToDelete: MailFolder?
    @State private var isConfirmingDelete = false
    @State private var folderToEmpty: MailFolder?
    @State private var isConfirmingEmpty = false

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
                Section(isExpanded: isExpanded(account)) {
                    // If the last check of this account failed, say why (it stays until a check works).
                    if let problem = store.accountProblems[account.id] {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(problem)
                    }
                    let tree = FolderNode.tree(from: store.foldersByAccount[account.id] ?? [])
                    // OutlineGroup shows a tree: each node's `children` appear nested under it.
                    OutlineGroup(tree.filter(\.isMainFolder), children: \.children) { node in
                        folderRow(node)
                    }
                    let otherFolders = tree.filter { !$0.isMainFolder }
                    if !otherFolders.isEmpty {
                        DisclosureGroup(isExpanded: isShowingMoreFolders(account)) {
                            OutlineGroup(otherFolders, children: \.children) { node in
                                folderRow(node)
                            }
                        } label: {
                            Label("More Folders", systemImage: "folder")
                                .contextMenu {
                                    Button("New Folder…") { askForName(.create(accountID: account.id, parent: nil)) }
                                }
                        }
                    }
                } header: {
                    Text(account.emailAddress)
                        .contextMenu {
                            Button("New Folder…") { askForName(.create(accountID: account.id, parent: nil)) }
                        }
                }
            }
        }
        // The box that asks for a folder name. `presenting:` hands the request to the buttons.
        .alert(nameRequest?.title ?? "", isPresented: $isAskingForName, presenting: nameRequest) { request in
            TextField("Folder name", text: $typedFolderName)
            Button(request.buttonTitle) { submitFolderName(for: request) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the folder “\(folderToDelete?.displayName ?? "")”?",
                            isPresented: $isConfirmingDelete, presenting: folderToDelete) { folder in
            Button("Delete Folder", role: .destructive) { delete(folder) }
        } message: { _ in
            Text("The folder and the messages in it are removed from the server. (In Gmail, the messages stay in All Mail.) This can't be undone.")
        }
        .confirmationDialog("Permanently delete everything in “\(folderToEmpty?.displayName ?? "")”?",
                            isPresented: $isConfirmingEmpty, presenting: folderToEmpty) { folder in
            Button("Empty \(folder.displayName)", role: .destructive) {
                Task { await store.emptyFolder(folder) }
            }
        } message: { _ in
            Text("This can't be undone.")
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

    // Whether an account's "More Folders" group is open, saved in accountsShowingMoreFolders.
    private func isShowingMoreFolders(_ account: AccountSettings) -> Binding<Bool> {
        let id = account.id.uuidString
        return Binding(
            get: { accountsShowingMoreFolders.split(separator: ",").contains(Substring(id)) },
            set: { showing in
                var ids = accountsShowingMoreFolders.split(separator: ",").map(String.init).filter { $0 != id }
                if showing { ids.append(id) }
                accountsShowingMoreFolders = ids.joined(separator: ",")
            }
        )
    }

    private func folderRow(_ node: FolderNode) -> some View {
        Label(node.name, systemImage: node.folder.role.iconName)
            .badge(node.folder.unreadCount)   // a count of 0 shows no badge
            .tag(node.folder.id)              // what gets stored when this row is selected
            // Accept messages dragged from the message list.
            .dropDestination(for: String.self) { items, _ in
                guard let messageIDs = items.first.flatMap({ MessageDrag.parse($0) }) else { return false }
                return dropMessages(messageIDs, node.folder)
            }
            .contextMenu { folderMenu(for: node.folder) }
    }

    // The right-click menu for a folder.
    // `@ViewBuilder` lets this function list several views (here, menu items) with `if`s between them.
    @ViewBuilder
    private func folderMenu(for folder: MailFolder) -> some View {
        Button("New Folder…") { askForName(.create(accountID: folder.accountID, parent: folder)) }
        if folder.role.canBeRenamedOrDeleted {
            Button("Rename Folder…") { askForName(.rename(folder)) }
            Button("Delete Folder…", role: .destructive) {
                folderToDelete = folder
                isConfirmingDelete = true
            }
        }
        Divider()
        Button("Mark All as Read") { Task { await store.markAllRead(in: folder) } }
            .disabled(folder.unreadCount == 0)
        if folder.role == .trash || folder.role == .junk {
            Button("Empty \(folder.displayName)…", role: .destructive) {
                folderToEmpty = folder
                isConfirmingEmpty = true
            }
        }
    }

    // Opens the folder name box, filled in with the current name when renaming.
    private func askForName(_ request: FolderNameRequest) {
        nameRequest = request
        typedFolderName = if case .rename(let folder) = request { folder.displayName } else { "" }
        isAskingForName = true
    }

    private func submitFolderName(for request: FolderNameRequest) {
        let name = typedFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            switch request {
            case .create(let accountID, let parent):
                await store.createFolder(named: name, inAccount: accountID, inside: parent)
            case .rename(let folder):
                // If the renamed folder was selected, keep it selected under its new name.
                if let newID = await store.renameFolder(folder, to: name), selectedFolderID == folder.id {
                    selectedFolderID = newID
                }
            }
        }
    }

    private func delete(_ folder: MailFolder) {
        Task {
            // If the deleted folder was selected, show that account's Inbox instead.
            if await store.deleteFolder(folder), selectedFolderID == folder.id {
                selectedFolderID = store.foldersByAccount[folder.accountID]?.first { $0.role == .inbox }?.id
            }
        }
    }
}

// What the folder name box is for.
private enum FolderNameRequest {
    case create(accountID: UUID, parent: MailFolder?)   // nil parent: a top-level folder
    case rename(MailFolder)

    var title: String {
        switch self {
        case .create(_, let parent): parent.map { "New Folder in “\($0.displayName)”" } ?? "New Folder"
        case .rename(let folder): "Rename “\(folder.displayName)”"
        }
    }

    var buttonTitle: String {
        switch self {
        case .create: "Create"
        case .rename: "Rename"
        }
    }
}

// One folder in the sidebar's tree, with the folders inside it.
struct FolderNode: Identifiable {
    let folder: MailFolder
    let name: String               // e.g. "Arrow" when it sits inside "Jobs"
    var children: [FolderNode]?    // nil (not empty) for no children, so no arrow is shown

    var id: MailFolder.ID { folder.id }

    // Inbox, Drafts, Sent, Trash and Junk always show; the rest go in "More Folders".
    var isMainFolder: Bool { [.inbox, .drafts, .sent, .trash, .junk].contains(folder.role) }

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
