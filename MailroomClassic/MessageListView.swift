// The middle pane: the messages in the selected folder, shown as a table with
// columns, newest first. Unread messages are bold, flagged ones show a red
// flag, and right-clicking a message offers read/unread, flag and delete.

import SwiftUI

// The things you can do to a message from its right-click menu.
enum MessageAction {
    case toggleRead, toggleFlag, delete
}

struct MessageListView: View {
    let messages: [MailMessage]   // already sorted newest first by MailStore
    @Binding var selectedMessageID: MailMessage.ID?
    let perform: (MessageAction, MailMessage) -> Void   // ContentView decides how to carry these out

    var body: some View {
        Table(messages, selection: $selectedMessageID) {
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
        }
        // Right-click menu. `ids` is the set of rows the menu is for (one row here).
        .contextMenu(forSelectionType: MailMessage.ID.self) { ids in
            if let id = ids.first, let message = messages.first(where: { $0.id == id }) {
                Button(message.isRead ? "Mark as Unread" : "Mark as Read") { perform(.toggleRead, message) }
                Button(message.isFlagged ? "Clear Flag" : "Flag") { perform(.toggleFlag, message) }
                Divider()
                Button("Delete", role: .destructive) { perform(.delete, message) }
            }
        }
    }
}
