// The main window: puts the three panes side by side (folders | message list |
// reading pane), or with the reading pane under the message list if you choose
// View → Reading Pane → Bottom. It adds the classic Outlook toolbar across the top and a status
// bar along the bottom, loads mail as you click around, and checks for new
// mail automatically every few minutes. The message list can show one folder,
// or All Inboxes (every account's Inbox mixed together), so actions work out
// which folder and account each message really belongs to.

import SwiftUI

struct ContentView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow   // used to open compose windows

    // `@State` is data this view owns and watches: when it changes, SwiftUI
    // redraws whatever depends on it. Here: which folder and messages are selected.
    @State private var selectedFolderID: String?   // a folder's ID, or MailFolder.allInboxesID
    @State private var selection: Set<MailMessage.ID> = []   // a Set, because several can be selected
    @State private var isConfirmingPermanentDelete = false
    @State private var messagesToDeletePermanently: [MailMessage] = []
    @State private var searchText = ""
    @State private var allowRemoteContent = false   // "Download Pictures" clicked for the open message

    // `@AppStorage` reads a saved setting (the Settings window writes it). 0 = check manually only.
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 5
    @AppStorage("readingPaneAtBottom") private var readingPaneAtBottom = false   // set from the View menu

    // The selected folder, or nil if none (or All Inboxes) is selected.
    private var selectedFolder: MailFolder? {
        store.allFolders.first { $0.id == selectedFolderID }
    }

    private var isShowingAllInboxes: Bool {
        selectedFolderID == MailFolder.allInboxesID
    }

    // The real folders the message list is showing: every Inbox for All Inboxes,
    // otherwise just the selected folder.
    private var shownFolders: [MailFolder] {
        if isShowingAllInboxes {
            return store.allFolders.filter { $0.role == .inbox }
        }
        return selectedFolder.map { [$0] } ?? []   // `.map` on an optional: [folder] if there is one, else []
    }

    private var selectedMessages: [MailMessage] {
        store.messages.filter { selection.contains($0.id) }
    }

    // The one selected message, or nil if none or several are selected.
    private var selectedMessage: MailMessage? {
        selection.count == 1 ? selectedMessages.first : nil
    }

    // The folder the selected message is in (which, in All Inboxes, could be any account's Inbox).
    private var selectedMessageFolder: MailFolder? {
        selectedMessage.flatMap { store.folder(of: $0) }
    }

    // The account to reply from or start a new email in: the selected message's
    // account, otherwise the selected folder's.
    private var selectedAccount: AccountSettings? {
        let accountID = (selectedMessageFolder ?? selectedFolder)?.accountID
        return store.accounts.first { $0.id == accountID }
    }

    // Folders the messages could be moved to, for "Move To": the other folders in
    // their account. Messages from different accounts can't be moved together.
    private func moveTargets(for messages: [MailMessage]) -> [MailFolder] {
        let groups = groupedByFolder(messages)
        let accountIDs = Set(groups.map(\.folder.accountID))
        guard accountIDs.count == 1, let accountID = accountIDs.first else { return [] }
        let currentFolderIDs = Set(groups.map(\.folder.id))
        return (store.foldersByAccount[accountID] ?? []).filter { !currentFolderIDs.contains($0.id) }
    }

    // Where Junk sends messages from `folder`: that account's Junk folder, or back
    // to its Inbox ("Not Junk") if they're already in Junk.
    private func junkDestination(for folder: MailFolder) -> MailFolder? {
        let role: FolderRole = folder.role == .junk ? .inbox : .junk
        return store.foldersByAccount[folder.accountID]?.first { $0.role == role }
    }

    // True if every selected message's account has somewhere for Junk to send it.
    private var canMoveSelectionToJunk: Bool {
        !selection.isEmpty && groupedByFolder(selectedMessages).allSatisfy { junkDestination(for: $0.folder) != nil }
    }

    private var folderCount: Int {
        store.allFolders.count
    }

    // Reply, Forward and Print need exactly one message, downloaded so it can be quoted or printed.
    private var canReplyOrForward: Bool {
        selectedMessage != nil && store.openMessage != nil
    }

    var body: some View {
        panes
        .navigationTitle(isShowingAllInboxes ? "All Inboxes" : selectedFolder?.displayName ?? "Mailroom Classic")
        // A search box in the toolbar. Pressing Return asks the server to search this folder.
        .searchable(text: $searchText, placement: .toolbar, prompt: isShowingAllInboxes ? "Search all inboxes" : "Search this folder")
        .onSubmit(of: .search) {
            guard let viewID = selectedFolderID, !shownFolders.isEmpty, !searchText.isEmpty else { return }
            selection = []
            Task { await store.search(searchText, in: shownFolders, viewID: viewID) }
        }
        .onChange(of: searchText) {
            // Clearing the search box (or clicking its ✕) goes back to the normal list.
            if searchText.isEmpty, store.isShowingSearchResults {
                Task { await loadShownFolders() }
            }
        }
        // A status bar along the bottom of the window, like classic Outlook.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text(store.statusText)
                    .lineLimit(1)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
        // `.task` runs async work when the window appears.
        .task {
            if NewMailNotifier.isEnabled {
                NewMailNotifier.requestPermission()
            }
            // Show the folders saved last time first, so you can read straight away.
            await store.showSavedFolders()
            selectFirstInboxIfNeeded()
            await store.refreshAllFolders()
            selectFirstInboxIfNeeded()
        }
        // Checks for new mail every few minutes. `.task(id:)` restarts this loop
        // whenever you change the interval in Settings, and stops it when the window closes.
        .task(id: checkIntervalMinutes) {
            guard checkIntervalMinutes > 0 else { return }   // "Manually" in Settings
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(checkIntervalMinutes * 60))
                guard !Task.isCancelled else { return }
                await sendReceive()
            }
        }
        // `.task(id:)` also runs again every time the id changes, cancelling the
        // previous run, so clicking quickly between folders or messages is safe.
        .task(id: selectedFolderID) {
            selection = []
            searchText = ""
            await loadShownFolders()
        }
        .task(id: selectedMessage?.id) {
            allowRemoteContent = false   // each message starts with internet pictures blocked
            guard let message = selectedMessage, let folder = selectedMessageFolder else {
                store.closeMessage()
                return
            }
            await store.open(message, in: folder)
        }
        // When an account is added in Settings, select its Inbox if nothing is selected yet
        // (or, if you're looking at All Inboxes, add the new Inbox to it).
        .onChange(of: folderCount) {
            selectFirstInboxIfNeeded()
            if isShowingAllInboxes {
                Task { await loadShownFolders() }
            }
        }
        .toolbar { toolbarButtons }
        // Hands File → Print… (⌘P) the action to run while this window is in front.
        // nil greys the menu item out.
        .focusedSceneValue(\.printMessage, canReplyOrForward ? selectedMessage.map { PrintAction(messageID: $0.id) { printMessage() } } : nil)
        // `presenting:` hands the waiting messages to the dialog's buttons.
        .confirmationDialog(
            messagesToDeletePermanently.count == 1
                ? "Permanently delete this message?"
                : "Permanently delete \(messagesToDeletePermanently.count) messages?",
            isPresented: $isConfirmingPermanentDelete,
            presenting: messagesToDeletePermanently
        ) { messages in
            Button("Delete", role: .destructive) {
                Task { await delete(messages) }
            }
        } message: { _ in
            Text("They will be erased from the server and can't be recovered.")
        }
    }

    // MARK: - Pieces of the window

    // NavigationSplitView is SwiftUI's built-in multi-column layout. With the
    // reading pane on the right it has three columns; with it at the bottom it has
    // two, and the second is split top/bottom by a VSplitView (a draggable divider).
    @ViewBuilder
    private var panes: some View {
        if readingPaneAtBottom {
            NavigationSplitView {
                folderSidebar
            } detail: {
                // `maxWidth: .infinity` makes each pane stretch across the whole window.
                VSplitView {
                    messageListColumn
                        .frame(maxWidth: .infinity, minHeight: 120)
                    readingPaneColumn
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        } else {
            NavigationSplitView {
                folderSidebar
            } content: {
                messageListColumn
                    .navigationSplitViewColumnWidth(min: 300, ideal: 450)
            } detail: {
                readingPaneColumn
            }
        }
    }

    private var folderSidebar: some View {
        FolderSidebarView(selectedFolderID: $selectedFolderID) { messageIDs, destination in
            dropMessages(messageIDs, onto: destination)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    // `@ToolbarContentBuilder` lets this property hold a list of toolbar items.
    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup {
            Button("New Email", systemImage: "square.and.pencil") {
                openWindow(id: "compose", value: ComposeDraft(accountID: selectedAccount?.id))
            }
            .help("New Email (⌘N)")
            .disabled(store.accounts.isEmpty)
            Button("Print", systemImage: "printer") {
                printMessage()
            }
            .help("Print (⌘P)")
            .disabled(!canReplyOrForward)
        }
        ToolbarItemGroup {
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                reply(replyAll: false)
            }
            .help("Reply (⌘R)")
            .keyboardShortcut("r")
            .disabled(!canReplyOrForward)
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                reply(replyAll: true)
            }
            .help("Reply All (⇧⌘R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!canReplyOrForward)
            Button("Forward", systemImage: "arrowshape.turn.up.right") {
                forward()
            }
            .help("Forward (⇧⌘F)")
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!canReplyOrForward)
        }
        ToolbarItemGroup {
            Button("Delete", systemImage: "trash") {
                requestDelete(selectedMessages)
            }
            .help("Delete (⌫)")
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selection.isEmpty)
            let isInJunk = selectedFolder?.role == .junk
            Button(isInJunk ? "Not Junk" : "Junk", systemImage: isInJunk ? "tray.and.arrow.up" : "xmark.bin") {
                perform(.junk, on: selectedMessages)
            }
            .help(isInJunk ? "Not Junk: move back to the Inbox (⇧⌘J)" : "Junk: move to the Junk folder (⇧⌘J)")
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(!canMoveSelectionToJunk)
        }
        ToolbarItemGroup {
            // If any selected message is unread, the button marks them all read; otherwise unread.
            let anyUnread = selectedMessages.contains { !$0.isRead }
            Button(anyUnread ? "Mark as Read" : "Mark as Unread", systemImage: "envelope.badge") {
                perform(anyUnread ? .markRead : .markUnread, on: selectedMessages)
            }
            .help("Mark as Read/Unread (⇧⌘U)")
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(selection.isEmpty)
            let anyUnflagged = selectedMessages.contains { !$0.isFlagged }
            Button(anyUnflagged ? "Flag" : "Clear Flag", systemImage: "flag") {
                perform(anyUnflagged ? .flag : .clearFlag, on: selectedMessages)
            }
            .help("Flag (⇧⌘L)")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(selection.isEmpty)
        }
        ToolbarItemGroup {
            Button("Send/Receive", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sendReceive() }
            }
            .help("Send/Receive")
        }
    }

    // The middle column: the message list, plus "Show Older Messages" when there are more.
    private var messageListColumn: some View {
        VStack(spacing: 0) {
            MessageListView(messages: store.messages, selection: $selection,
                            moveTargets: { moveTargets(for: $0) }) { action, messages in
                perform(action, on: messages)
            }
            if store.hasOlderMessages, let viewID = selectedFolderID {
                Button("Show Older Messages") {
                    Task { await store.loadOlderMessages(from: shownFolders, viewID: viewID) }
                }
                .buttonStyle(.link)
                .padding(6)
            }
        }
    }

    // The right column: the reading pane, a count when several messages are
    // selected, or a welcome message when there are no accounts yet.
    @ViewBuilder   // lets this property return different kinds of views from an if/else
    private var readingPaneColumn: some View {
        if store.accounts.isEmpty {
            ContentUnavailableView {
                Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an email account to get started.")
            } actions: {
                SettingsLink { Text("Add Account…") }   // opens the Settings window
            }
        } else if selection.count > 1 {
            ContentUnavailableView("\(selection.count) Messages Selected", systemImage: "tray.full")
        } else {
            // Only drafts get an "Edit Draft" button.
            let editAction: (() -> Void)? = selectedMessageFolder?.role == .drafts ? { editDraft() } : nil
            ReadingPaneView(message: selectedMessage, openMessage: store.openMessage, editDraft: editAction,
                            allowRemoteContent: $allowRemoteContent)
        }
    }

    // MARK: - Actions

    // Splits messages up by the folder they're really in. In a normal folder
    // that's one group; in All Inboxes there's one group per account's Inbox.
    private func groupedByFolder(_ messages: [MailMessage]) -> [(folder: MailFolder, messages: [MailMessage])] {
        // `Dictionary(grouping:by:)` sorts items into buckets, here keyed by folder ID.
        Dictionary(grouping: messages, by: \.folderID).compactMap { folderID, group in
            store.allFolders.first { $0.id == folderID }.map { (folder: $0, messages: group) }
        }
    }

    // Carries out a message action (from the toolbar or the right-click menu),
    // one folder's worth of messages at a time, since each folder may belong to a different account.
    private func perform(_ action: MessageAction, on messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        switch action {
        case .delete:
            requestDelete(messages)
            return
        case .junk, .move:
            deselect(messages)   // they're about to leave this list
        default:
            break
        }
        Task {
            for (folder, group) in groupedByFolder(messages) {
                switch action {
                case .markRead: await store.setRead(true, for: group, in: folder)
                case .markUnread: await store.setRead(false, for: group, in: folder)
                case .flag: await store.setFlagged(true, for: group, in: folder)
                case .clearFlag: await store.setFlagged(false, for: group, in: folder)
                case .junk:
                    if let destination = junkDestination(for: folder) {
                        await store.moveMessages(group, from: folder, to: destination)
                    }
                case .move(let destination): await store.moveMessages(group, from: folder, to: destination)
                case .delete: break   // handled above
                }
            }
        }
    }

    // Handles messages dropped onto a sidebar folder. Returns false to refuse the drop,
    // e.g. when they're from a different account, or already in that folder.
    private func dropMessages(_ messageIDs: [MailMessage.ID], onto destination: MailFolder) -> Bool {
        let dropped = store.messages.filter { messageIDs.contains($0.id) && $0.folderID != destination.id }
        let sameAccount = groupedByFolder(dropped).allSatisfy { $0.folder.accountID == destination.accountID }
        guard !dropped.isEmpty, sameAccount else { return false }
        perform(.move(to: destination), on: dropped)
        return true
    }

    // Opens a compose window pre-filled as a reply to the selected message.
    private func reply(replyAll: Bool) {
        guard let message = selectedMessage, let account = selectedAccount else { return }
        let draft = ComposeDraft.reply(to: message, body: store.openMessage?.plainText ?? "",
                                       account: account, replyAll: replyAll)
        openWindow(id: "compose", value: draft)
    }

    // Opens a compose window pre-filled as a forward, with the original's attachments.
    private func forward() {
        guard let message = selectedMessage, let account = selectedAccount, let contents = store.openMessage else { return }
        Task {
            // The compose window attaches files from disk, so download the attachments to temporary files first.
            let attachmentURLs = await store.downloadToTemporaryFiles(contents.attachments)
            let draft = ComposeDraft.forward(message, body: contents.plainText, attachmentURLs: attachmentURLs, account: account)
            openWindow(id: "compose", value: draft)
        }
    }

    // Prints the open message, with internet pictures only if you allowed them.
    private func printMessage() {
        guard let message = selectedMessage, let contents = store.openMessage else { return }
        MessagePrinter.print(message, contents: contents, allowRemoteContent: allowRemoteContent, from: NSApp.keyWindow)
    }

    // Re-opens the selected draft in a compose window.
    private func editDraft() {
        guard let message = selectedMessage, let account = selectedAccount, let contents = store.openMessage else { return }
        Task {
            let attachmentURLs = await store.downloadToTemporaryFiles(contents.attachments)
            openWindow(id: "compose", value: ComposeDraft.editing(message, contents: contents, attachmentURLs: attachmentURLs, account: account))
        }
    }

    // Deleting from Trash is permanent, so ask first. Elsewhere it just moves to Trash.
    private func requestDelete(_ messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        if groupedByFolder(messages).contains(where: { $0.folder.role == .trash }) {
            messagesToDeletePermanently = messages
            isConfirmingPermanentDelete = true
        } else {
            Task { await delete(messages) }
        }
    }

    private func delete(_ messages: [MailMessage]) async {
        deselect(messages)
        for (folder, group) in groupedByFolder(messages) {
            await store.deleteMessages(group, in: folder)
        }
    }

    // Removes messages from the selection (e.g. before they're moved away).
    private func deselect(_ messages: [MailMessage]) {
        selection.subtract(messages.map(\.id))
    }

    // Reloads folders and unread counts, then the open folder's message list.
    private func sendReceive() async {
        await store.refreshAllFolders()
        if !store.isShowingSearchResults {
            await loadShownFolders()
        }
    }

    // Loads the message list for whatever is selected in the sidebar.
    private func loadShownFolders() async {
        guard let viewID = selectedFolderID, !shownFolders.isEmpty else { return }
        await store.loadMessages(from: shownFolders, viewID: viewID)
    }

    // Folders are sorted Inbox-first, so the first folder is the first account's Inbox.
    private func selectFirstInboxIfNeeded() {
        if selectedFolderID == nil || (!isShowingAllInboxes && selectedFolder == nil) {
            selectedFolderID = store.allFolders.first?.id
        }
    }
}

#Preview {
    ContentView()
        .environment(MailStore())
}
