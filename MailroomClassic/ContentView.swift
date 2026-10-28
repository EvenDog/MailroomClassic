// The main window: puts the three panes side by side (folders | message list |
// reading pane), or with the reading pane under the message list if you choose
// View → Reading Pane → Bottom. It adds the classic Outlook toolbar across the top and a status
// bar along the bottom, loads mail as you click around, and checks for new
// mail automatically every few minutes. The message list can show one folder,
// or All Inboxes (every account's Inbox mixed together), so actions work out
// which folder and account each message really belongs to. Moves and deletes
// can be undone (⌘Z), the status bar offers Undo for an email that's about to
// be sent, the list can show only unread or flagged mail, and email links
// (mailto:) clicked in other apps open a new email here. Selecting the Outbox
// shows emails waiting to be sent later, which are sent here when they're due.

import SwiftUI

struct ContentView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow   // used to open compose and message windows
    // The window's undo list: what Edit → Undo (⌘Z) takes back.
    @Environment(\.undoManager) private var undoManager

    // `@State` is data this view owns and watches: when it changes, SwiftUI
    // redraws whatever depends on it. Here: which folder and messages are selected.
    @State private var selectedFolderID: String?   // a folder's ID, or MailFolder.allInboxesID
    @State private var selection: Set<MailMessage.ID> = []   // a Set, because several can be selected
    @State private var isConfirmingPermanentDelete = false
    @State private var messagesToDeletePermanently: [MailMessage] = []
    @State private var searchText = ""
    @State private var allowRemoteContent = false   // "Download Pictures" clicked for the open message
    @State private var messageFilter = MessageFilter.all   // All / Unread / Flagged, above the list
    @State private var searchScope = SearchScope.thisFolder   // the choice under the search box
    // A message to select as soon as it appears in the list (from a clicked notification).
    @State private var messageToSelect: MailMessage.ID?
    // Follow Up → Choose Date & Time…: the messages it's for, the time picked, and whether its sheet is showing.
    @State private var messagesToFollowUp: [MailMessage] = []
    @State private var followUpTime = Date()
    @State private var isPickingFollowUpTime = false

    // `@AppStorage` reads a saved setting (the Settings window writes it). 0 = check manually only.
    @AppStorage("checkIntervalMinutes") private var checkIntervalMinutes = 5
    @AppStorage("readingPaneAtBottom") private var readingPaneAtBottom = false   // set from the View menu
    @AppStorage("showPreviewText") private var showPreviewText = true            // View → Preview Text
    @AppStorage(MessageListDensity.storageKey) private var messageListDensity = MessageListDensity.comfortable
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system   // Settings → Appearance

    // The selected folder, or nil if none (or All Inboxes) is selected.
    private var selectedFolder: MailFolder? {
        store.allFolders.first { $0.id == selectedFolderID }
    }

    private var isShowingAllInboxes: Bool {
        selectedFolderID == MailFolder.allInboxesID
    }

    private var isShowingOutbox: Bool {
        selectedFolderID == MailFolder.outboxID
    }

    // The real folders the message list is showing: every Inbox for All Inboxes,
    // otherwise just the selected folder.
    private var shownFolders: [MailFolder] {
        if isShowingAllInboxes {
            return store.allFolders.filter { $0.role == .inbox }
        }
        return selectedFolder.map { [$0] } ?? []   // `.map` on an optional: [folder] if there is one, else []
    }

    // The messages the list shows, after the All / Unread / Flagged filter.
    // Selected messages always stay, so a message you're reading doesn't vanish
    // the moment it's marked read; it goes when you click another one.
    private var shownMessages: [MailMessage] {
        switch messageFilter {
        case .all: store.messages
        case .unread: store.messages.filter { !$0.isRead || selection.contains($0.id) }
        case .flagged: store.messages.filter { $0.isFlagged || selection.contains($0.id) }
        }
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

    // Folders the messages could be moved to, for "Move To": every folder they're
    // not already in, account by account. If the messages all come from one
    // account, that account comes first (Move To lists its folders directly).
    private func moveTargets(for messages: [MailMessage]) -> [MoveTargetGroup] {
        let groups = groupedByFolder(messages)
        let sourceAccountIDs = Set(groups.map(\.folder.accountID))
        let ownAccountID = sourceAccountIDs.count == 1 ? sourceAccountIDs.first : nil
        let currentFolderIDs = Set(groups.map(\.folder.id))
        let targets = store.accounts.map { account in
            MoveTargetGroup(accountID: account.id, accountName: account.displayName,
                            folders: (store.foldersByAccount[account.id] ?? []).filter { !currentFolderIDs.contains($0.id) },
                            isMessagesOwnAccount: account.id == ownAccountID)
        }
        let ownAccountFirst = targets.filter(\.isMessagesOwnAccount) + targets.filter { !$0.isMessagesOwnAccount }
        return ownAccountFirst.filter { !$0.folders.isEmpty }
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
        // Split in two (`searchableWindow`, then the rest here) because one very long
        // chain of modifiers is too much for the Swift compiler to work out in one go.
        searchableWindow
        // `.task` runs async work when the window appears.
        .task {
            if NewMailNotifier.isEnabled {
                NewMailNotifier.requestPermission()
            }
            // Its own task, so mail loads while macOS asks about Contacts (the first time).
            Task { await ContactsBook.shared.load() }
            // Show the folders saved last time first, so you can read straight away.
            await store.showSavedFolders()
            selectFirstInboxIfNeeded()
            showMailFromNotification()   // in case a notification click opened this window
            await store.refreshAllFolders()
            selectFirstInboxIfNeeded()
        }
        .onChange(of: store.mailToShow) { showMailFromNotification() }
        // After the Mac wakes from sleep, push's connections are dead, so open new ones
        // rather than waiting until they're next tested (up to 5 minutes later). The
        // short wait gives the Wi-Fi time to reconnect first.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task {
                try? await Task.sleep(for: .seconds(10))
                store.restartPush()
            }
        }
        // As messages load into the list, select the one a notification asked for.
        .onChange(of: store.messages.count) { selectWaitingMessage() }
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
        // Sends Outbox emails when their time comes: checked every 30 seconds,
        // starting at launch (for any that came due while the app was closed).
        .task {
            while !Task.isCancelled {
                await store.sendDueScheduledEmails()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // `.task(id:)` also runs again every time the id changes, cancelling the
        // previous run, so clicking quickly between folders or messages is safe.
        .task(id: selectedFolderID) {
            selection = []
            searchText = ""
            messageFilter = .all   // each folder starts showing everything
            await loadShownFolders()
        }
        .task(id: selectedMessage?.id) {
            // Each message starts with internet pictures blocked, unless its sender is
            // on the "always download" list.
            allowRemoteContent = selectedMessage.map { PictureSenders.picturesAllowed(for: $0, in: selectedMessageFolder) } ?? false
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
        // Opens a compose window for each email that came back from Undo Send or failed to send.
        .onChange(of: store.draftsToReopen) {
            guard !store.draftsToReopen.isEmpty else { return }
            for draft in store.draftsToReopen {
                openWindow(id: "compose", value: draft)
            }
            store.draftsToReopen = []
        }
        // An email link (mailto:) clicked in another app or a website: start a new email.
        // (This needs Mailroom Classic set as the default email app; see Settings.)
        .onOpenURL { url in
            if let draft = ComposeDraft.fromMailtoLink(url) {
                openWindow(id: "compose", value: draft)
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
        .sheet(isPresented: $isPickingFollowUpTime) {
            followUpTimeSheet
        }
    }

    // Follow Up → Choose Date & Time…: the due date, and the time to be reminded that day.
    private var followUpTimeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Follow Up")
                .font(.headline)
            DatePicker("Remind me on", selection: $followUpTime, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPickingFollowUpTime = false }
                Button("Flag") {
                    isPickingFollowUpTime = false
                    perform(.followUp(.at(followUpTime)), on: messagesToFollowUp)
                }
                .keyboardShortcut(.defaultAction)   // Return clicks it
            }
        }
        .padding()
        .frame(width: 340)
    }

    // The panes, with the search box and the status bar.
    private var searchableWindow: some View {
        panes
        .navigationTitle(isShowingAllInboxes ? "All Inboxes" : isShowingOutbox ? "Outbox" : selectedFolder?.displayName ?? "Mailroom Classic")
        .navigationSubtitle(listSummary)   // the smaller line under the title
        // A search box in the toolbar. Pressing Return searches.
        .searchable(text: $searchText, placement: .toolbar, prompt: searchPrompt)
        // The choice that appears under the search box while you search: this folder, or every folder.
        .searchScopes($searchScope) {
            Text(isShowingAllInboxes ? "All Inboxes" : "This Folder").tag(SearchScope.thisFolder)
            Text("All Folders").tag(SearchScope.allFolders)
        }
        .onSubmit(of: .search) { runSearch() }
        // Switching between This Folder and All Folders runs the search again.
        .onChange(of: searchScope) {
            if store.isShowingSearchResults { runSearch() }
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
                // An email waiting out its Undo Send delay (the newest, if there are several).
                if let pending = store.pendingSends.last {
                    undoSendBar(for: pending)
                    Spacer()
                }
                // Shown while messages download for offline reading (see MailStore.downloadForOffline).
                if let progress = store.offlineDownloadProgress {
                    Text(progress)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
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
            Menu("Follow Up", systemImage: "calendar.badge.clock") {
                FollowUpMenuItems { perform(.followUp($0), on: selectedMessages) }
            }
            .help("Follow Up: flag with a due date and a reminder")
            .disabled(selection.isEmpty)
            Menu("Categorize", systemImage: "tag") {
                CategorizeMenuItems(messages: selectedMessages) { perform($0, on: selectedMessages) }
            }
            .help("Categorize: add color categories")
            .disabled(selection.isEmpty)
        }
        ToolbarItemGroup {
            Button("Send/Receive", systemImage: "arrow.triangle.2.circlepath") {
                Task { await sendReceive() }
            }
            .help("Send/Receive")
        }
    }

    private var searchPrompt: String {
        if searchScope == .allFolders { return "Search all folders" }
        return isShowingAllInboxes ? "Search all inboxes" : "Search this folder"
    }

    // Searches the shown folder (or All Inboxes), or every folder, for what's in the search box.
    private func runSearch() {
        guard let viewID = selectedFolderID, !shownFolders.isEmpty, !searchText.isEmpty else { return }
        selection = []
        let query = searchText
        Task {
            if searchScope == .allFolders {
                await store.searchAllFolders(query, viewID: viewID)
            } else {
                await store.search(query, in: shownFolders, viewID: viewID)
            }
        }
    }

    // "Sending “Lunch?” in 0:07  Undo" in the status bar.
    private func undoSendBar(for pending: PendingSend) -> some View {
        HStack(spacing: 6) {
            Text("Sending “\(pending.draft.subject.isEmpty ? "Untitled Message" : pending.draft.subject)” in")
                .lineLimit(1)
            // `Text(timerInterval:countsDown:)` is a built-in countdown that redraws itself every second.
            let waitStarted = pending.sendsAt.addingTimeInterval(-MailStore.undoSendDelay)
            Text(timerInterval: waitStarted...pending.sendsAt, countsDown: true)
                .monospacedDigit()
            Button("Undo") { store.undoSend(pending) }
                .buttonStyle(.link)
        }
    }

    // The middle column: the All / Unread / Flagged filter, the message list,
    // and "Show Older Messages" when there are more. Or the Outbox, if that's selected.
    @ViewBuilder
    private var messageListColumn: some View {
        if isShowingOutbox {
            OutboxView()
                .background(appearance.colors?.list ?? .clear)
        } else {
            mailListColumn
        }
    }

    private var mailListColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $messageFilter) {
                    ForEach(MessageFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()   // only as wide as its three buttons
                Spacer()
                // Also in View → Message List.
                Picker("Message List", selection: $messageListDensity) {
                    ForEach(MessageListDensity.allCases, id: \.self) { density in
                        Text(density.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Comfortable: two lines per message, with a preview. Compact: one line per message, in columns.")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            MessageListView(messages: shownMessages, selection: $selection,
                            folderName: folderColumnText,
                            previewText: showPreviewText ? { store.previews[$0.id] } : nil,
                            dueDate: { store.followUp(for: $0)?.dueDate },
                            moveTargets: { moveTargets(for: $0) }) { action, messages in
                perform(action, on: messages)
            }
            // `.overlay` draws on top of the (empty) list.
            .overlay {
                if shownMessages.isEmpty && messageFilter != .all {
                    ContentUnavailableView(messageFilter == .unread ? "No Unread Messages" : "No Flagged Messages",
                                           systemImage: messageFilter == .unread ? "envelope.open" : "flag")
                }
            }
            if store.hasOlderMessages, let viewID = selectedFolderID {
                Button("Show Older Messages") {
                    Task { await store.loadOlderMessages(from: shownFolders, viewID: viewID) }
                }
                .buttonStyle(.link)
                .padding(6)
            }
        }
        .background(appearance.colors?.list ?? .clear)   // an in-between theme's list color, behind the bar above the list too
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
        } else if isShowingOutbox {
            ContentUnavailableView("Outbox", systemImage: "clock",
                                   description: Text("Click Edit next to an email to change it."))
        } else if selection.count > 1 {
            ContentUnavailableView("\(selection.count) Messages Selected", systemImage: "tray.full")
        } else {
            // Only drafts get an "Edit Draft" button.
            let editAction: (() -> Void)? = selectedMessageFolder?.role == .drafts ? { editDraft() } : nil
            ReadingPaneView(message: selectedMessage, openMessage: store.openMessage, editDraft: editAction,
                            allowRemoteContent: $allowRemoteContent)
        }
    }

    // Under the window title, e.g. "8 messages, 4 unread" (or "12 found" while searching).
    private var listSummary: String {
        if isShowingOutbox {
            return store.scheduledEmails.count == 1 ? "1 email waiting" : "\(store.scheduledEmails.count) emails waiting"
        }
        let count = store.messages.count
        if store.isShowingSearchResults { return "\(count.formatted()) found" }
        let messages = count == 1 ? "1 message" : "\(count.formatted()) messages"
        let unread = store.messages.filter { !$0.isRead }.count
        return unread == 0 ? messages : "\(messages), \(unread.formatted()) unread"
    }

    // What the Folder column shows, or nil to hide it: it's only there for All Folders search results.
    private var folderColumnText: ((MailMessage) -> String)? {
        guard store.isShowingSearchResults && store.searchCoversAllFolders else { return nil }
        return folderName(of:)
    }

    // For the Folder column in All Folders search results, e.g. "Receipts (Gmail)".
    private func folderName(of message: MailMessage) -> String {
        guard let folder = store.folder(of: message) else { return "" }
        let account = store.accounts.first { $0.id == folder.accountID }
        return store.accounts.count > 1 ? "\(folder.displayName) (\(account?.displayName ?? ""))" : folder.displayName
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
        case .open:
            openInWindows(messages)
            return
        case .followUp(.pickDate):
            // Ask for the date first; the sheet's Flag button then comes back here with it.
            messagesToFollowUp = messages
            followUpTime = FollowUpChoice.tomorrow.followUp()?.remindAt ?? Date()
            isPickingFollowUpTime = true
            return
        case .junk, .move:
            deselect(messages)   // they're about to leave this list
        default:
            break
        }
        Task {
            var completedMoves: [CompletedMove] = []   // for Undo
            for (folder, group) in groupedByFolder(messages) {
                switch action {
                case .markRead: await store.setRead(true, for: group, in: folder)
                case .markUnread: await store.setRead(false, for: group, in: folder)
                case .flag: await store.setFlagged(true, for: group, in: folder)
                case .clearFlag: await store.setFlagged(false, for: group, in: folder)
                case .junk:
                    if let destination = junkDestination(for: folder),
                       let move = await store.moveMessages(group, from: folder, to: destination) {
                        completedMoves.append(move)
                    }
                case .move(let destination):
                    if let move = await store.moveMessages(group, from: folder, to: destination) {
                        completedMoves.append(move)
                    }
                case .followUp(let choice): await store.setFollowUp(choice, for: group, in: folder)
                case .setCategory(let category, let isOn): await store.setCategory(category, isOn: isOn, for: group, in: folder)
                case .clearCategories: await store.clearCategories(of: group, in: folder)
                case .delete, .open: break   // handled above
                }
            }
            registerUndo(completedMoves, named: "Move")
        }
    }

    // Puts moves or deletes that just happened on the window's undo list, so
    // Edit → Undo (⌘Z) moves the messages back. `named` is what the menu says, e.g. "Undo Delete".
    private func registerUndo(_ moves: [CompletedMove], named actionName: String) {
        guard !moves.isEmpty, let undoManager else { return }
        // `registerUndo(withTarget:)` stores a little piece of code to run if you choose Undo.
        undoManager.registerUndo(withTarget: store) { store in
            Task {
                for move in moves {
                    await store.undo(move)
                }
            }
        }
        undoManager.setActionName(actionName)
    }

    // Double-click (or Return, or right-click → Open): each message in its own window.
    // A draft opens for editing instead. At most 10 at once, so ⌘A then Return
    // can't open hundreds of windows.
    private func openInWindows(_ messages: [MailMessage]) {
        if messages.count == 1, let message = messages.first, store.folder(of: message)?.role == .drafts {
            editDraft()
            return
        }
        for message in messages.prefix(10) {
            openWindow(id: "message", value: message.id)
        }
    }

    // Handles messages dropped onto a sidebar folder, in any account. Returns false
    // to refuse the drop, e.g. when they're all already in that folder.
    private func dropMessages(_ messageIDs: [MailMessage.ID], onto destination: MailFolder) -> Bool {
        let dropped = store.messages.filter { messageIDs.contains($0.id) && $0.folderID != destination.id }
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
        var completedMoves: [CompletedMove] = []   // moves into Trash, for Undo
        for (folder, group) in groupedByFolder(messages) {
            if let move = await store.deleteMessages(group, in: folder) {
                completedMoves.append(move)
            }
        }
        registerUndo(completedMoves, named: "Delete")
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

    // Shows the email from a clicked new-mail notification: goes to its folder
    // (or stays in All Inboxes, which includes it), then selects it once it's in the list.
    private func showMailFromNotification() {
        guard let request = store.mailToShow else { return }
        store.mailToShow = nil
        searchText = ""
        let folderIsAnInbox = store.allFolders.first { $0.id == request.folderID }?.role == .inbox
        if !(isShowingAllInboxes && folderIsAnInbox) {
            selectedFolderID = request.folderID
        }
        messageToSelect = request.messageID
        selectWaitingMessage()
    }

    private func selectWaitingMessage() {
        guard let messageID = messageToSelect, store.messages.contains(where: { $0.id == messageID }) else { return }
        messageFilter = .all
        selection = [messageID]
        messageToSelect = nil
    }

    // Folders are sorted Inbox-first, so the first folder is the first account's Inbox.
    private func selectFirstInboxIfNeeded() {
        if selectedFolderID == nil || (!isShowingAllInboxes && !isShowingOutbox && selectedFolder == nil) {
            selectedFolderID = store.allFolders.first?.id
        }
    }
}

// The choices under the search box.
enum SearchScope {
    case thisFolder, allFolders
}

// The choices above the message list.
enum MessageFilter: String, CaseIterable {
    case all = "All", unread = "Unread", flagged = "Flagged"
}

#Preview {
    ContentView()
        .environment(MailStore())
}
