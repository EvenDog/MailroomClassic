// The middle pane: the messages in the selected folder, shown as a table with
// columns, newest first (click the From, Subject or Received header to sort by
// that instead). Unread messages are bold, flagged ones show a red flag. You can select several (⌘-click, ⇧-click), drag them onto a folder,
// and right-click for read/unread, flag, move and delete. When sorted by From
// or Subject, typing a letter jumps to the first message starting with it.
// Columns can be dragged into a different order, resized, and hidden or shown
// (right-click the column headers); the layout is remembered. When sorted by
// date, messages are grouped under classic Outlook headings: Today, Yesterday…
// and each group can be collapsed with the arrow next to its heading.

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

    // The columns' order, widths and which are hidden, as you've arranged them.
    // `@AppStorage` saves it in the app's settings, so it's the same next launch.
    @AppStorage("messageListColumns") private var columnCustomization = TableColumnCustomization<MailMessage>()

    private var sortedMessages: [MailMessage] {
        messages.sorted(using: sortOrder)
    }

    // The date headings whose groups are collapsed (e.g. "Last Week").
    @State private var collapsedHeadings: Set<String> = []

    // Type-to-select: the letters typed so far, and when the last one was typed.
    @State private var typedText = ""
    @State private var lastTypedAt = Date.distantPast

    var body: some View {
        // ScrollViewReader lets us scroll the table to a row (`proxy.scrollTo`).
        ScrollViewReader { proxy in
            messageTable
                // Runs when a letter or number is typed while the table is focused.
                .onKeyPress(characters: .alphanumerics, phases: .down) { keyPress in
                    jumpToMessage(startingWith: keyPress, scroll: proxy)
                }
        }
    }

    // Type-to-select, like Finder and classic Outlook: selects the first message
    // whose sender (or subject, if sorted by that) starts with the typed letters.
    // Letters typed within a second of each other add up ("d", "a" → "da").
    // Returns whether the key press was used, so others (like ⌘A) still work.
    private func jumpToMessage(startingWith keyPress: KeyPress, scroll proxy: ScrollViewProxy) -> KeyPress.Result {
        guard keyPress.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        // The column the list is sorted by decides what the letters are matched against.
        let textOf: (MailMessage) -> String
        switch sortOrder.first?.keyPath {
        case \MailMessage.senderDisplayName: textOf = \.senderDisplayName
        case \MailMessage.subject: textOf = \.subject
        default: return .ignored   // sorted by date: letters mean nothing
        }

        typedText = Date().timeIntervalSince(lastTypedAt) < 1 ? typedText + keyPress.characters : keyPress.characters
        lastTypedAt = Date()
        // `.anchored` means "at the start"; the others ignore capitals and accents.
        let match = sortedMessages.first {
            textOf($0).range(of: typedText, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }
        if let match {
            selection = [match.id]
            proxy.scrollTo(match.id)
        }
        return .handled
    }

    private var messageTable: some View {
        // `customizationID` is the name each column's position, width and
        // visibility are saved under. `width(min:ideal:)` lets you drag a column
        // anywhere from `min` wide to as wide as you like.
        Table(of: MailMessage.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            // The small columns' headers are icons, like classic Outlook's.
            // `Text(Image(…))` puts an icon where a title would go.
            TableColumn(Text(Image(systemName: "envelope"))) { message in
                Image(systemName: message.isRead ? "envelope.open" : "envelope.fill")
                    .foregroundStyle(.secondary)
            }
            .width(min: 16, ideal: 20)
            .customizationID("read")

            TableColumn(Text(Image(systemName: "paperclip"))) { message in
                if message.hasAttachments {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 16, ideal: 16)
            .customizationID("attachment")

            // `value:` is what clicking this column's header sorts by.
            TableColumn("From", value: \.senderDisplayName) { message in
                Text(message.senderDisplayName)
                    .fontWeight(message.isRead ? .regular : .bold)
            }
            .width(min: 30, ideal: 150)
            .customizationID("from")

            TableColumn("Subject", value: \.subject) { message in
                Text(message.subject)
                    .fontWeight(message.isRead ? .regular : .bold)
            }
            .customizationID("subject")

            TableColumn("Received", value: \.dateReceived) { message in
                Text(message.dateReceived, format: .dateTime.month().day().hour().minute())
            }
            .width(min: 30, ideal: 120)
            .customizationID("received")

            TableColumn(Text(Image(systemName: "flag"))) { message in
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.red)
                }
            }
            .width(min: 16, ideal: 16)
            .customizationID("flag")
        } rows: {
            if sortOrder.first?.keyPath == \MailMessage.dateReceived {
                // Group headings. Sorted by date, each heading's messages sit together,
                // so a heading's title is unique and can serve as its ID.
                ForEach(dateGroups, id: \.title) { group in
                    Section(group.title, isExpanded: isExpanded(group.title)) {
                        ForEach(group.messages) { message in
                            row(for: message)
                        }
                    }
                }
            } else {
                ForEach(sortedMessages) { message in
                    row(for: message)
                }
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

    // One message's row. Each row can be dragged; the payload is worked out when the drag starts.
    private func row(for message: MailMessage) -> some TableRowContent<MailMessage> {
        TableRow(message)
            .draggable(dragPayload(startingWith: message))
    }

    // Whether a date heading's group is showing; collapsing adds it to collapsedHeadings.
    private func isExpanded(_ heading: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedHeadings.contains(heading) },
            set: { expanded in
                if expanded { collapsedHeadings.remove(heading) } else { collapsedHeadings.insert(heading) }
            }
        )
    }

    // The sorted messages split into runs that share a date heading, in order.
    private var dateGroups: [(title: String, messages: [MailMessage])] {
        var groups: [(title: String, messages: [MailMessage])] = []
        for message in sortedMessages {
            let title = DateHeading.title(for: message.dateReceived)
            if groups.last?.title == title {
                groups[groups.count - 1].messages.append(message)
            } else {
                groups.append((title, [message]))
            }
        }
        return groups
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

// Classic Outlook's date headings for the message list.
enum DateHeading {
    // The heading for a message received at `date`, as seen at `now`: Today,
    // Yesterday, a weekday name earlier this week, Last Week, Two Weeks Ago,
    // Three Weeks Ago, Earlier This Month, Last Month, or Older.
    static func title(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if date >= today { return "Today" }   // (a date in the future counts as today too)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return "Yesterday" }

        // `dateInterval(of: .weekOfYear…)` is the week containing `now`; weeks start
        // on Sunday or Monday depending on your Mac's region settings.
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        if date >= startOfWeek {
            return date.formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))   // e.g. "Monday"
        }
        for (weeksAgo, heading) in [(1, "Last Week"), (2, "Two Weeks Ago"), (3, "Three Weeks Ago")] {
            if let start = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: startOfWeek), date >= start {
                return heading
            }
        }
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        if date >= startOfMonth { return "Earlier This Month" }
        if let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfMonth), date >= startOfLastMonth {
            return "Last Month"
        }
        return "Older"
    }
}
