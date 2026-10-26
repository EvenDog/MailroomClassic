// The main window: puts the three panes side by side (folders | message list |
// reading pane), adds the classic Outlook toolbar across the top and a status
// bar along the bottom, and loads mail as you click around.

import SwiftUI

struct ContentView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow   // used to open compose windows

    // `@State` is data this view owns and watches: when it changes, SwiftUI
    // redraws whatever depends on it. Here: which folder and message are selected.
    @State private var selectedFolderID: MailFolder.ID?
    @State private var selectedMessageID: MailMessage.ID?
    @State private var isConfirmingPermanentDelete = false
    @State private var messageToDeletePermanently: MailMessage?

    private var selectedFolder: MailFolder? {
        store.allFolders.first { $0.id == selectedFolderID }
    }

    private var selectedMessage: MailMessage? {
        store.messages.first { $0.id == selectedMessageID }
    }

    private var selectedAccount: AccountSettings? {
        store.accounts.first { $0.id == selectedFolder?.accountID }
    }

    // Reply and Forward wait until the body has downloaded, so it can be quoted.
    private var canReplyOrForward: Bool {
        selectedMessage != nil && store.openMessage != nil
    }

    var body: some View {
        // NavigationSplitView is SwiftUI's built-in multi-column layout.
        // With three closures it makes three resizable columns.
        NavigationSplitView {
            FolderSidebarView(selectedFolderID: $selectedFolderID)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            MessageListView(messages: store.messages, selectedMessageID: $selectedMessageID) { action, message in
                switch action {
                case .toggleRead: toggleRead(message)
                case .toggleFlag: toggleFlag(message)
                case .delete: requestDelete(message)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 450)
        } detail: {
            if store.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No Accounts", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add an email account to get started.")
                } actions: {
                    SettingsLink { Text("Add Account…") }   // opens the Settings window
                }
            } else {
                ReadingPaneView(message: selectedMessage, openMessage: store.openMessage)
            }
        }
        .navigationTitle(selectedFolder?.displayName ?? "Mailroom Classic")
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
            await store.refreshAllFolders()
            selectFirstInboxIfNeeded()
        }
        // `.task(id:)` runs again every time the id changes, and automatically
        // cancels the previous run, so clicking quickly between folders is safe.
        .task(id: selectedFolderID) {
            selectedMessageID = nil
            guard let folder = selectedFolder else { return }
            await store.loadMessages(in: folder)
        }
        .task(id: selectedMessageID) {
            guard let message = selectedMessage, let folder = selectedFolder else {
                store.closeMessage()
                return
            }
            await store.open(message, in: folder)
        }
        // When an account is added in Settings, select its Inbox if nothing is selected yet.
        .onChange(of: store.allFolders.count) {
            selectFirstInboxIfNeeded()
        }
        .toolbar {
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
                    if let selectedMessage { requestDelete(selectedMessage) }
                }
                .help("Delete (⌫)")
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(selectedMessage == nil)
            }
            ToolbarItemGroup {
                Button(selectedMessage?.isRead == false ? "Mark as Read" : "Mark as Unread", systemImage: "envelope.badge") {
                    if let selectedMessage { toggleRead(selectedMessage) }
                }
                .help("Mark as Read/Unread (⇧⌘U)")
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(selectedMessage == nil)
                Button(selectedMessage?.isFlagged == true ? "Clear Flag" : "Flag", systemImage: "flag") {
                    if let selectedMessage { toggleFlag(selectedMessage) }
                }
                .help("Flag (⇧⌘L)")
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(selectedMessage == nil)
            }
            ToolbarItemGroup {
                Button("Send/Receive", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await sendReceive() }
                }
                .help("Send/Receive")
            }
        }
        // `presenting:` hands the waiting message to the dialog's buttons.
        .confirmationDialog("Permanently delete this message?", isPresented: $isConfirmingPermanentDelete,
                            presenting: messageToDeletePermanently) { message in
            Button("Delete", role: .destructive) {
                Task { await delete(message) }
            }
        } message: { _ in
            Text("It will be erased from the server and can't be recovered.")
        }
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

    private func toggleRead(_ message: MailMessage) {
        guard let folder = selectedFolder else { return }
        Task { await store.setRead(!message.isRead, for: message, in: folder) }
    }

    private func toggleFlag(_ message: MailMessage) {
        guard let folder = selectedFolder else { return }
        Task { await store.setFlagged(!message.isFlagged, for: message, in: folder) }
    }

    // Deleting from Trash is permanent, so ask first. Elsewhere it just moves to Trash.
    private func requestDelete(_ message: MailMessage) {
        if selectedFolder?.role == .trash {
            messageToDeletePermanently = message
            isConfirmingPermanentDelete = true
        } else {
            Task { await delete(message) }
        }
    }

    private func delete(_ message: MailMessage) async {
        guard let folder = selectedFolder else { return }
        if selectedMessageID == message.id {
            selectedMessageID = nil   // closes the reading pane
        }
        await store.deleteMessage(message, in: folder)
    }

    // Reloads folders and unread counts, then the open folder's message list.
    private func sendReceive() async {
        await store.refreshAllFolders()
        if let folder = selectedFolder {
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
