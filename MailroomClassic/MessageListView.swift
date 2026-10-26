// The middle pane: the messages in the selected folder, shown as a table with
// columns, newest first (click the From, Subject or Received header to sort by
// that instead). Unread messages are bold, flagged ones show a red flag. You can select several (⌘-click, ⇧-click), drag them onto a folder,
// and right-click for read/unread, flag, move and delete.

import SwiftUI

// The things you can do to messages (from the toolbar or the right-click menu).
enum MessageAction {
    case markRead, markUnread, flag, clearFlag, delete
    case junk   // to the Junk folder, or back to the Inbox if already in Junk
    case move(to: MailFolder)
}

struct MessageListView: View {
    let messages: [MailMessage]   // already sorted newest first by MailStore
    @Binding var selection: Set<MailMessage.ID>
    // The folders the given messages could be moved to (for "Move To").
    let moveTargets: ([MailMessage]) -> [MailFolder]
    let perform: (MessageAction, [MailMessage]) -> Void   // ContentView decides how to carry these out

    // Which column the list is sorted by, and which way. Clicking a column header changes it.
    // A KeyPathComparator sorts by one property (`\.dateReceived` means "each message's dateReceived").
    @State private var sortOrder = [KeyPathComparator(\MailMessage.dateReceived, order: .reverse)]

    private var sortedMessages: [MailMessage] {
        messages.sorted(using: sortOrder)
    }

    var body: some View {
        Table(of: MailMessage.self, selection: $selection, sortOrder: $sortOrder) {
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

            // `value:` is what clicking this column's header sorts by.
            TableColumn("From", value: \.senderDisplayName) { message in
                Text(message.senderDisplayName)
                    .fontWeight(message.isRead ? .regular : .bold)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Subject", value: \.subject) { message in
                Text(message.subject)
                    .fontWeight(message.isRead ? .regular : .bold)
            }

            TableColumn("Received", value: \.dateReceived) { message in
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
            ForEach(sortedMessages) { message in
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
                let targets = moveTargets(chosen)
                Menu("Move To") {
                    ForEach(targets) { folder in
                        Button(folder.displayName) { perform(.move(to: folder), chosen) }
                    }
                }
                .disabled(targets.isEmpty)
                Divider()
                Button("Delete", role: .destructive) { perform(.delete, chosen) }
            }
        }
    }

    // What gets dragged: every selected message if you drag one of them,
    // otherwise just the row you grabbed.
    private func dragPayload(startingWith message: MailMessage) -> String {
        MessageDrag.payload(messageIDs: selection.contains(message.id) ? Array(selection) : [message.id])
    }
}

// The text that travels with a drag: a first line saying it's ours, then one
// message ID per line. (Message IDs can contain "/" and "|" but never a new line.)
enum MessageDrag {
    private static let prefix = "mailroom-classic-move"

    static func payload(messageIDs: [MailMessage.ID]) -> String {
        ([prefix] + messageIDs).joined(separator: "\n")
    }

    // Reads a payload back. Returns nil for anything else (e.g. text dragged from another app).
    static func parse(_ text: String) -> [MailMessage.ID]? {
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.first == prefix, lines.count > 1 else { return nil }
        return Array(lines.dropFirst())
    }
}
