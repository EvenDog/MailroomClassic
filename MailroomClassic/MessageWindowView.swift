// A message in its own window, opened by double-clicking it in the message list
// (or right-click → Open), like classic Outlook. It shows the same header,
// attachments and body as the reading pane, with Reply, Reply All, Forward and
// Print in its toolbar. The window keeps its copy of the message, so it stays
// open even after you click to another folder in the main window.

import SwiftUI

struct MessageWindowView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    let messageID: MailMessage.ID

    // Looked up once when the window opens (see `.task` below).
    @State private var message: MailMessage?
    @State private var contents: OpenMessage?
    @State private var allowRemoteContent = false   // "Download Pictures" for this window
    @State private var couldNotOpen = false

    // The account the message belongs to, for replying from.
    private var account: AccountSettings? {
        let accountID = message.flatMap { store.folder(of: $0) }?.accountID
        return store.accounts.first { $0.id == accountID }
    }

    var body: some View {
        Group {
            if couldNotOpen {
                ContentUnavailableView("This message isn't available", systemImage: "envelope",
                                       description: Text("Open it again from the message list."))
            } else {
                ReadingPaneView(message: message, openMessage: contents, editDraft: nil,
                                allowRemoteContent: $allowRemoteContent)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle(message?.subject ?? "Message")
        .toolbar {
            ToolbarItemGroup {
                // `Group` lets one `.disabled` cover all four buttons.
                Group {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(replyAll: false) }
                        .help("Reply (⌘R)")
                        .keyboardShortcut("r")
                    Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(replyAll: true) }
                        .help("Reply All (⇧⌘R)")
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { forward() }
                        .help("Forward (⇧⌘F)")
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("Print", systemImage: "printer") { printMessage() }
                        .help("Print (⌘P)")
                }
                .disabled(contents == nil || account == nil)
            }
        }
        // Lets File → Print… (⌘P) print this message while this window is in front.
        .focusedSceneValue(\.printMessage, contents == nil ? nil : message.map { PrintAction(messageID: $0.id) { printMessage() } })
        .focusedSceneValue(\.sourceMessageID, message?.id)   // for View → Message Source
        .task {
            // The main window's list has the message right now (you just double-clicked it).
            guard let found = store.messages.first(where: { $0.id == messageID }) else {
                couldNotOpen = true
                return
            }
            message = found
            allowRemoteContent = PictureSenders.picturesAllowed(for: found, in: store.folder(of: found))
            contents = await store.contents(of: found)
            couldNotOpen = contents == nil
        }
    }

    private func reply(replyAll: Bool) {
        guard let message, let contents, let account else { return }
        openWindow(id: "compose", value: ComposeDraft.reply(to: message, body: contents.plainText,
                                                            account: account, replyAll: replyAll))
    }

    private func forward() {
        guard let message, let contents, let account else { return }
        Task {
            // The compose window attaches files from disk, so download the attachments first.
            let attachmentURLs = await store.downloadToTemporaryFiles(contents.attachments)
            openWindow(id: "compose", value: ComposeDraft.forward(message, body: contents.plainText,
                                                                  attachmentURLs: attachmentURLs, account: account))
        }
    }

    private func printMessage() {
        guard let message, let contents else { return }
        MessagePrinter.print(message, contents: contents, allowRemoteContent: allowRemoteContent, from: NSApp.keyWindow)
    }
}
