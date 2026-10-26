// The middle pane: the messages in the selected folder, shown as a table with
// columns, newest first. Unread messages are bold, flagged ones show a red
// flag. You can select several (⌘-click, ⇧-click), drag them onto a folder,
// and right-click for read/unread, flag, move and delete.

import SwiftUI

// The things you can do to messages from the right-click menu.
enum MessageAction {
    case markRead, markUnread, flag, clearFlag, delete
    case move(to: MailFolder)
}

struct MessageListView: View {
    let messages: [MailMessage]   // already sorted newest first by MailStore
    @Binding var selection: Set<MailMessage.ID>
    let sourceFolder: MailFolder?            // the folder being shown (for drag and drop)
    let moveTargets: [MailFolder]            // other folders in the same account
    let perform: (MessageAction, [MailMessage]) -> Void   // ContentView decides how to carry these out

    var body: some View {
        Table(of: MailMessage.self, selection: $selection) {
            TableColumn("") { message in
                Image(systemName: message.isRead ? "envelope.open" : "envelope.fill")
                    .foregroundStyle(.secondary)
            }
            .width(20)

            TableColumn("") { message in
                if message.hasAttachments {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
            }
            .width(16)

            TableColumn("From") { message in
                Text(message.sender.name ?? message.sender.address)
                    .fontWeight(message.isRead ? .regular : .bold)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Subject") { message in
                Text(message.subject)
                    .fontWeight(message.isRead ? .regular : .bold)
            }

            TableColumn("Received") { message in
                Text(message.dateReceived, format: .dateTime.month().day().hour().minute())
            }
            .width(min: 90, ideal: 120)

            TableColumn("") { message in
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.red)
                }
            }
            .width(16)
        } rows: {
            ForEach(messages) { message in
                // Each row can be dragged; the payload is worked out when the drag starts.
                TableRow(message)
                    .draggable(dragPayload(startingWith: message))
            }
        }
        // Right-click menu. `ids` is the set of rows the menu applies to.
        .contextMenu(forSelectionType: MailMessage.ID.self) { ids in
            let chosen = messages.filter { ids.contains($0.id) }
            if !chosen.isEmpty {
                if chosen.contains(where: { !$0.isRead }) {
                    Button("Mark as Read") { perform(.markRead, chosen) }
                }
                if chosen.contains(where: \.isRead) {
                    Button("Mark as Unread") { perform(.markUnread, chosen) }
                }
                if chosen.contains(where: { !$0.isFlagged }) {
                    Button("Flag") { perform(.flag, chosen) }
                }
                if chosen.contains(where: \.isFlagged) {
                    Button("Clear Flag") { perform(.clearFlag, chosen) }
                }
                Divider()
                Menu("Move To") {
                    ForEach(moveTargets) { folder in
                        Button(folder.displayName) { perform(.move(to: folder), chosen) }
                    }
                }
                .disabled(moveTargets.isEmpty)
                Divider()
                Button("Delete", role: .destructive) { perform(.delete, chosen) }
            }
        }
    }

    // What gets dragged: every selected message if you drag one of them,
    // otherwise just the row you grabbed.
    private func dragPayload(startingWith message: MailMessage) -> String {
        let uids = selection.contains(message.id) ? Array(selection) : [message.uid]
        return MessageDrag.payload(uids: uids, from: sourceFolder?.id ?? "")
    }
}

// The text that travels with a drag: "mailroom-classic-move|uid,uid|source folder ID".
// The folder ID goes last because it may itself contain "|".
enum MessageDrag {
    private static let prefix = "mailroom-classic-move"

    static func payload(uids: [UInt32], from folderID: String) -> String {
        "\(prefix)|\(uids.map(String.init).joined(separator: ","))|\(folderID)"
    }

    // Reads a payload back. Returns nil for anything else (e.g. text dragged from another app).
    static func parse(_ text: String) -> (uids: [UInt32], sourceFolderID: String)? {
        let parts = text.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == prefix else { return nil }
        let uids = parts[1].split(separator: ",").compactMap { UInt32($0) }
        return uids.isEmpty ? nil : (uids, String(parts[2]))
    }
}
