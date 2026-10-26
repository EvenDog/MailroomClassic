// The main window: puts the three panes side by side (folders | message list |
// reading pane), adds the classic Outlook toolbar across the top and a status
// bar along the bottom, loads mail as you click around, and checks for new
// mail automatically every few minutes.

import SwiftUI

struct ContentView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow   // used to open compose windows

    // `@State` is data this view owns and watches: when it changes, SwiftUI
    // redraws whatever depends on it. Here: which folder and messages are selected.
    @State private var selectedFolderID: MailFolder.ID?
    @State private var selection: Set<MailMessage.ID> = []   // a Set, because several can be selected
    @State private var isConfirmingPermanentDelete = false
    @State private var messagesToDeletePermanently: [MailMessage] = []
    @State private var searchText = ""

    // `@AppStorage` reads a saved setting (the Settings window writes it). 0 = check manually only.
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 5

    private var selectedFolder: MailFolder? {
        store.allFolders.first { $0.id == selectedFolderID }
    }

    private var selectedMessages: [MailMessage] {
        store.messages.filter { selection.contains($0.id) }
    }

    // The one selected message, or nil if none or several are selected.
    private var selectedMessage: MailMessage? {
        selection.count == 1 ? selectedMessages.first : nil
    }

    private var selectedAccount: AccountSettings? {
        store.accounts.first { $0.id == selectedFolder?.accountID }
    }

    // The other folders in this account, for "Move To".
    private var moveTargets: [MailFolder] {
        guard let folder = selectedFolder else { return [] }
        return (store.foldersByAccount[folder.accountID] ?? []).filter { $0.id != folder.id }
    }

    // Where the Junk button sends messages: the Junk folder, or back to the
    // Inbox ("Not Junk") if you're already looking at Junk.
    private var junkButtonDestination: MailFolder? {
        guard let folder = selectedFolder else { return nil }
        let role: FolderRole = folder.role == .junk ? .inbox : .junk
        return store.foldersByAccount[folder.accountID]?.first { $0.role == role }
    }

    private var folderCount: Int {
        store.allFolders.count
    }

    // Reply and Forward need exactly one message, downloaded so it can be quoted.
    private var canReplyOrForward: Bool {
        selectedMessage != nil && store.openMessage != nil
    }

    var body: some View {
        // NavigationSplitView is SwiftUI's built-in multi-column layout.
        // With three closures it makes three resizable columns.
        NavigationSplitView {
            FolderSidebarView(selectedFolderID: $selectedFolderID) { uids, sourceFolderID, destination in
                dropMessages(uids: uids, from: sourceFolderID, onto: destination)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            messageListColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 450)
        } detail: {
            readingPaneColumn
        }
        .navigationTitle(selectedFolder?.displayName ?? "Mailroom Classic")
        // A search box in the toolbar. Pressing Return asks the server to search this folder.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search this folder")
        .onSubmit(of: .search) {
            guard let folder = selectedFolder, !searchText.isEmpty else { return }
            selection = []
            Task { await store.search(searchText, in: folder) }
        }
        .onChange(of: searchText) {
            // Clearing the search box (or clicking its ✕) goes back to the normal list.
            if searchText.isEmpty, store.isShowingSearchResults, let folder = selectedFolder {
                Task { await store.loadMessages(in: folder) }
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
            guard let folder = selectedFolder else { return }
            await store.loadMessages(in: folder)
        }
        .task(id: selectedMessage?.id) {
            guard let message = selectedMessage, let folder = selectedFolder else {
                store.closeMessage()
                return
            }
            await store.open(message, in: folder)
        }
        // When an account is added in Settings, select its Inbox if nothing is selected yet.
        .onChange(of: folderCount) {
            selectFirstInboxIfNeeded()
        }
        .toolbar { toolbarButtons }
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

    // `@ToolbarContentBuilder` lets this property hold a list of toolbar items.
    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItemGroup {
            Button("New Email", systemImage: "square.and.pencil") {
                openWindow(id: "compose", value: ComposeDraft(accountID: selectedAccount?.id))
            }
            .help("New Email (⌘N)")
            .disabled(store.accounts.isEmpty)
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
                if let destination = junkButtonDestination {
                    perform(.move(to: destination), on: selectedMessages)
                }
            }
            .help(isInJunk ? "Not Junk: move back to the Inbox (⇧⌘J)" : "Junk: move to the Junk folder (⇧⌘J)")
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(selection.isEmpty || junkButtonDestination == nil)
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
                            sourceFolder: selectedFolder, moveTargets: moveTargets) { action, messages in
                perform(action, on: messages)
            }
            if store.hasOlderMessages, let folder = selectedFolder {
                Button("Show Older Messages") {
                    Task { await store.loadOlderMessages(in: folder) }
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
            let editAction: (() -> Void)? = selectedFolder?.role == .drafts ? { editDraft() } : nil
            ReadingPaneView(message: selectedMessage, openMessage: store.openMessage, editDraft: editAction)
        }
    }

    // MARK: - Actions

    // Carries out a message action (from the toolbar or the right-click menu).
    private func perform(_ action: MessageAction, on messages: [MailMessage]) {
        guard let folder = selectedFolder, !messages.isEmpty else { return }
        switch action {
        case .markRead: Task { await store.setRead(true, for: messages, in: folder) }
        case .markUnread: Task { await store.setRead(false, for: messages, in: folder) }
        case .flag: Task { await store.setFlagged(true, for: messages, in: folder) }
        case .clearFlag: Task { await store.setFlagged(false, for: messages, in: folder) }
        case .delete: requestDelete(messages)
        case .move(let destination):
            deselect(messages)
            Task { await store.moveMessages(messages, from: folder, to: destination) }
        }
    }

    // Handles messages dropped onto a sidebar folder. Returns false to refuse the drop.
    private func dropMessages(uids: [UInt32], from sourceFolderID: String, onto destination: MailFolder) -> Bool {
        guard let folder = selectedFolder, sourceFolderID == folder.id,
              destination.id != folder.id, destination.accountID == folder.accountID else { return false }
        let dropped = store.messages.filter { uids.contains($0.uid) }
        guard !dropped.isEmpty else { return false }
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
        // The compose window attaches files from disk, so save the attachments to temporary files.
        // `try?` skips any that fail to save rather than stopping the whole forward.
        let attachmentURLs = contents.attachments.compactMap { try? AttachmentFiles.saveToTemporaryFolder($0) }
        let draft = ComposeDraft.forward(message, body: contents.plainText, attachmentURLs: attachmentURLs, account: account)
        openWindow(id: "compose", value: draft)
    }

    // Re-opens the selected draft in a compose window.
    private func editDraft() {
        guard let message = selectedMessage, let account = selectedAccount, let contents = store.openMessage else { return }
        let attachmentURLs = contents.attachments.compactMap { try? AttachmentFiles.saveToTemporaryFolder($0) }
        openWindow(id: "compose", value: ComposeDraft.editing(message, contents: contents, attachmentURLs: attachmentURLs, account: account))
    }

    // Deleting from Trash is permanent, so ask first. Elsewhere it just moves to Trash.
    private func requestDelete(_ messages: [MailMessage]) {
        guard !messages.isEmpty else { return }
        if selectedFolder?.role == .trash {
            messagesToDeletePermanently = messages
            isConfirmingPermanentDelete = true
        } else {
            Task { await delete(messages) }
        }
    }

    private func delete(_ messages: [MailMessage]) async {
        guard let folder = selectedFolder else { return }
        deselect(messages)
        await store.deleteMessages(messages, in: folder)
    }

    // Removes messages from the selection (e.g. before they're moved away).
    private func deselect(_ messages: [MailMessage]) {
        selection.subtract(messages.map(\.id))
    }

    // Reloads folders and unread counts, then the open folder's message list.
    private func sendReceive() async {
        await store.refreshAllFolders()
        if let folder = selectedFolder, !store.isShowingSearchResults {
            await store.loadMessages(in: folder)
        }
    }

    // Folders are sorted Inbox-first, so the first folder is the first account's Inbox.
    private func selectFirstInboxIfNeeded() {
        if selectedFolder == nil {
            selectedFolderID = store.allFolders.first?.id
        }
    }
}

#Preview {
    ContentView()
        .environment(MailStore())
}
