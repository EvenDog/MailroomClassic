// The middle pane: the messages in the selected folder, in one of two styles
// (see MessageListDensity). Comfortable: two-line rows with a preview, like Apple
// Mail, with a Sort menu. Compact, described below: a table with
// columns, newest first (click the From, Subject or Received header to sort by
// that instead). Unread messages are bold, flagged ones show a red flag (and
// their follow-up date, e.g. "Due Tomorrow", in red once it's due), color
// categories show as small colored dots, and the
// start of each message's text can show in grey after its subject. Search
// results from every folder get an extra Folder column. You can select several (⌘-click, ⇧-click), drag them onto a folder,
// and right-click for open, read/unread, flag, move and delete. Double-click
// (or Return) opens a message in its own window. When sorted by From
// or Subject, typing a letter jumps to the first message starting with it.
// Columns can be dragged into a different order, resized, and hidden or shown
// (right-click the column headers); the layout is remembered. When sorted by
// date, messages are grouped under classic Outlook headings: Today, Yesterday…
// and each group can be collapsed with the arrow next to its heading.
// View → Show as Conversations tucks each conversation's older messages under
// its newest one (see Conversations).

import SwiftUI

// The things you can do to messages (from the toolbar or the right-click menu).
enum MessageAction {
    case open   // in its own window
    case markRead, markUnread, flag, clearFlag, delete
    case junk   // to the Junk folder, or back to the Inbox if already in Junk
    case move(to: MailFolder)
    case followUp(FollowUpChoice)   // flag with a due date (see FollowUp)
    case setCategory(MailCategory, isOn: Bool)   // add or remove a color category (see Categories)
    case clearCategories
}

// The Follow Up menu's items, shared by the toolbar and the right-click menu.
// `choose` is called with the picked choice.
struct FollowUpMenuItems: View {
    let choose: (FollowUpChoice) -> Void

    var body: some View {
        ForEach(FollowUpChoice.quickChoices, id: \.self) { choice in
            Button(choice.title) { choose(choice) }
        }
        Divider()
        Button(FollowUpChoice.pickDate.title) { choose(.pickDate) }
    }
}

// How the message list looks, chosen above the list or in View → Message List
// and saved in the app's settings: two-line rows with a preview (Comfortable),
// or one-line rows in sortable columns (Compact).
enum MessageListDensity: String, CaseIterable {
    case comfortable = "Comfortable"
    case compact = "Compact"

    static let storageKey = "messageListDensity"

    // The icon for its button above the message list (an SF Symbol, Apple's built-in icons).
    var symbolName: String {
        switch self {
        case .comfortable: "rectangle.grid.1x2"   // two stacked boxes: two-line rows
        case .compact: "line.3.horizontal"        // thin lines: one-line rows
        }
    }

    // The button's tooltip.
    var helpText: String {
        switch self {
        case .comfortable: "Comfortable: two lines per message, with a preview"
        case .compact: "Compact: one line per message, in columns"
        }
    }
}

// One account's folders in the Move To menu. The messages' own account's folders
// are listed in the menu itself; each other account gets a submenu.
struct MoveTargetGroup: Identifiable {
    let accountID: UUID
    let accountName: String
    let folders: [MailFolder]
    let isMessagesOwnAccount: Bool

    var id: UUID { accountID }
}

struct MessageListView: View {
    let messages: [MailMessage]   // already sorted newest first by MailStore
    @Binding var selection: Set<MailMessage.ID>
    // The list reports here which messages it shows, top to bottom, so the main
    // window knows which one is "next" after a delete or move.
    @Binding var displayedOrder: [MailMessage.ID]
    // Names each message's folder, for the Folder column. nil hides that column
    // (it's only shown for search results from every folder).
    let folderName: ((MailMessage) -> String)?
    // The start of a message's text, shown in grey after its subject, or nil if
    // there isn't one yet. nil (the whole thing) turns preview lines off.
    let previewText: ((MailMessage) -> String?)?
    // A flagged message's follow-up due date, if it has one.
    let dueDate: (MailMessage) -> Date?
    // The folders the given messages could be moved to (for "Move To"), by account.
    let moveTargets: ([MailMessage]) -> [MoveTargetGroup]
    let perform: (MessageAction, [MailMessage]) -> Void   // ContentView decides how to carry these out

    // Which column the list is sorted by, and which way. Clicking a column header changes it.
    // A KeyPathComparator sorts by one property (`\.dateReceived` means "each message's dateReceived").
    @State private var sortOrder = [KeyPathComparator(\MailMessage.dateReceived, order: .reverse)]

    // The columns' order, widths and which are hidden, as you've arranged them.
    // `@AppStorage` saves it in the app's settings, so it's the same next launch.
    @AppStorage("messageListColumns") private var columnCustomization = TableColumnCustomization<MailMessage>()

    // View → Show as Conversations: replies tucked under the newest message of
    // their conversation. Only while sorted by date, since a conversation spans dates.
    @AppStorage("showConversations") private var showConversations = false

    private var sortedMessages: [MailMessage] {
        messages.sorted(using: sortOrder)
    }

    private var isSortedByDate: Bool {
        sortOrder.first?.keyPath == \MailMessage.dateReceived
    }

    // The date headings whose groups are collapsed (e.g. "Last Week").
    @State private var collapsedHeadings: Set<String> = []

    // Type-to-select: the letters typed so far, and when the last one was typed.
    @State private var typedText = ""
    @State private var lastTypedAt = Date.distantPast

    // Comfortable (two-line rows) or Compact (one-line rows in columns); see MessageListDensity.
    @AppStorage(MessageListDensity.storageKey) private var density = MessageListDensity.comfortable
    // For the in-between themes' list color (see AppAppearance).
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some View {
        // ScrollViewReader lets us scroll the list to a row (`proxy.scrollTo`).
        ScrollViewReader { proxy in
            Group {
                switch density {
                case .comfortable: comfortableList
                case .compact: messageTable
                }
            }
            // Runs when a letter or number is typed while the list is focused.
            .onKeyPress(characters: .alphanumerics, phases: .down) { keyPress in
                jumpToMessage(startingWith: keyPress, scroll: proxy)
            }
        }
        // `initial: true` also reports it when the list first appears.
        .onChange(of: rowOrder, initial: true) {
            displayedOrder = rowOrder
        }
    }

    // Every message in the order its row appears, top to bottom: sorted, under
    // the date headings (leaving out collapsed ones), each conversation's newest
    // message followed by the rest of it.
    private var rowOrder: [MailMessage.ID] {
        if showConversations && isSortedByDate {
            return conversationDateGroups(orderedConversations)
                .filter { !collapsedHeadings.contains($0.title) }
                .flatMap { $0.conversations.flatMap { $0.messages.map(\.id) } }
        } else if isSortedByDate {
            return dateGroups
                .filter { !collapsedHeadings.contains($0.title) }
                .flatMap { $0.messages.map(\.id) }
        }
        return sortedMessages.map(\.id)
    }

    // MARK: - Comfortable: two-line rows

    // Each message takes two or three lines: sender and time, then the subject,
    // then (with View → Preview Text on) the start of its text, like Apple Mail.
    // There are no column headers to click, so the Sort menu above it picks the order.
    // Date headings, conversations, selecting, the right-click menu and dragging
    // work as in the Compact table.
    private var comfortableList: some View {
        let conversations = showConversations && isSortedByDate ? orderedConversations : []
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                sortMenu
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)

            List(selection: $selection) {
                if !conversations.isEmpty {
                    ForEach(conversationDateGroups(conversations), id: \.title) { group in
                        Section(isExpanded: isExpanded(group.title)) {
                            ForEach(group.conversations) { conversation in
                                comfortableRows(for: conversation)
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                } else if isSortedByDate {
                    ForEach(dateGroups, id: \.title) { group in
                        Section(isExpanded: isExpanded(group.title)) {
                            ForEach(group.messages) { message in
                                comfortableRow(message)
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                } else {
                    ForEach(sortedMessages) { message in
                        comfortableRow(message)
                    }
                }
            }
            .listStyle(.inset)
            .themeBackground(appearance.colors?.list)
            .contextMenu(forSelectionType: MailMessage.ID.self, menu: messageMenu, primaryAction: openMessages)
        }
    }

    // A conversation in the Comfortable list: just the message if it's on its own;
    // otherwise its newest message, with an arrow that shows the others under it.
    @ViewBuilder
    private func comfortableRows(for conversation: Conversation) -> some View {
        if conversation.messages.count == 1 {
            comfortableRow(conversation.newest)
        } else {
            let others = conversation.messages.dropFirst()
            DisclosureGroup {
                ForEach(others) { message in
                    comfortableRow(message)
                }
            } label: {
                comfortableRow(conversation.newest, conversationSize: conversation.messages.count,
                               hasUnreadReplies: others.contains { !$0.isRead })
            }
        }
    }

    // One message in the Comfortable list. A conversation's newest message also
    // shows how many messages the conversation holds (in bold if any of the
    // hidden ones are unread).
    private func comfortableRow(_ message: MailMessage, conversationSize: Int? = nil, hasUnreadReplies: Bool = false) -> some View {
        // On the selected row the highlight is the accent color, so the unread dot turns white.
        let isSelected = selection.contains(message.id)
        return HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(message.isRead ? Color.clear : (isSelected ? Color.white : Color.accentColor))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityLabel(message.isRead ? "" : "Unread")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(message.senderDisplayName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    CategoryDots(categories: message.categories)
                    Spacer(minLength: 6)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                    }
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(isSelected ? .white : .red)
                    }
                    if let due = dueDate(message) {
                        dueLabel(due)
                            .font(.callout)
                    }
                    Text(DateHeading.shortText(for: message.dateReceived))
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                HStack(spacing: 6) {
                    Text(message.subject)
                        .lineLimit(1)
                    if let conversationSize {
                        Text("\(conversationSize) messages")
                            .fontWeight(hasUnreadReplies ? .bold : .regular)
                            .foregroundStyle(.secondary)
                    }
                }
                // `previewText?(message)` calls the function only if there is one (Preview Text is on).
                if let preview = previewText?(message) {
                    Text(preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .tag(message.id)   // what gets stored in `selection` when this row is clicked
        .draggable(dragPayload(startingWith: message))
    }

    // "Due Tomorrow", in red once it's due today or overdue.
    private func dueLabel(_ dueDate: Date) -> some View {
        Text(FollowUps.dueText(for: dueDate))
            .foregroundStyle(FollowUps.isDueNow(dueDate) ? .red : .secondary)
            .lineLimit(1)
    }

    // The Comfortable list's stand-in for clicking column headers.
    private var sortMenu: some View {
        Menu("Sort by \(sortName)") {
            Button("Date, Newest First") { sortOrder = [KeyPathComparator(\MailMessage.dateReceived, order: .reverse)] }
            Button("Date, Oldest First") { sortOrder = [KeyPathComparator(\MailMessage.dateReceived, order: .forward)] }
            Button("From") { sortOrder = [KeyPathComparator(\MailMessage.senderDisplayName)] }
            Button("Subject") { sortOrder = [KeyPathComparator(\MailMessage.subject)] }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()   // only as wide as its title
        .font(.callout)
    }

    // What the list is sorted by, for the Sort menu's title.
    private var sortName: String {
        switch sortOrder.first?.keyPath {
        case \MailMessage.senderDisplayName: "From"
        case \MailMessage.subject: "Subject"
        default: sortOrder.first?.order == .forward ? "Date, Oldest First" : "Date"
        }
    }

    // MARK: - Compact: one-line rows in columns

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
        // Worked out once per redraw: the rows and the Subject column both use them.
        let conversations = showConversations && isSortedByDate ? orderedConversations : []
        let conversationInfo = Dictionary(uniqueKeysWithValues: conversations.filter { $0.messages.count > 1 }.map {
            ($0.id, (count: $0.messages.count, hasUnreadReplies: $0.messages.dropFirst().contains { !$0.isRead }))
        })

        // `customizationID` is the name each column's position, width and
        // visibility are saved under. `width(min:ideal:)` lets you drag a column
        // anywhere from `min` wide to as wide as you like. Each `min` is the
        // narrowest the column can be while still showing what's in it.
        return Table(of: MailMessage.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            // The small columns' headers are icons, like classic Outlook's.
            // `Text(Image(…))` puts an icon where a title would go.
            TableColumn(Text(Image(systemName: "envelope"))) { message in
                Image(systemName: message.isRead ? "envelope.open" : "envelope.fill")
                    .foregroundStyle(.secondary)
            }
            .width(min: 36, ideal: 36)   // room for the icon plus the date heading's indent
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
            .width(min: 80, ideal: 150)
            .customizationID("from")

            TableColumn("Subject", value: \.subject) { message in
                // The preview goes after the subject on the same line: the table's rows
                // are one line tall, so a second line under the subject would be cut off.
                HStack(spacing: 6) {
                    Text(message.subject)
                        .fontWeight(message.isRead ? .regular : .bold)
                        .layoutPriority(1)   // when space runs out, the preview gets shortened first
                    // A conversation's newest message shows how many messages it holds,
                    // in bold if any of the ones tucked under it are unread.
                    if let info = conversationInfo[message.id] {
                        Text("(\(info.count))")
                            .fontWeight(info.hasUnreadReplies ? .bold : .regular)
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    // `previewText?(message)` calls the function only if there is one;
                    // `if let` then also skips messages without a preview yet.
                    if let preview = previewText?(message) {
                        Text(preview)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .width(min: 120, ideal: 300)
            .customizationID("subject")

            // `if` inside a Table's columns: the column only exists while this is true.
            if let folderName {
                TableColumn("Folder") { message in
                    Text(folderName(message))
                }
                .width(min: 60, ideal: 90)
                .customizationID("folder")
            }

            TableColumn("Received", value: \.dateReceived) { message in
                Text(DateHeading.compactText(for: message.dateReceived))
                    // Hovering shows the full date and time, e.g. "Saturday, October 24, 2026 at 4:53 PM".
                    .help(message.dateReceived.formatted(date: .complete, time: .shortened))
            }
            .width(min: 85, ideal: 95)   // fits "Wed 12:45 PM"
            .customizationID("received")

            TableColumn(Text(Image(systemName: "flag"))) { message in
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.red)
                }
            }
            .width(min: 16, ideal: 16)
            .customizationID("flag")

            // A flagged message's follow-up date (see FollowUp).
            TableColumn("Due") { message in
                if let due = dueDate(message) {
                    dueLabel(due)
                }
            }
            .width(min: 70, ideal: 100)
            .customizationID("due")

            TableColumn("Categories") { message in
                CategoryDots(categories: message.categories)
            }
            .width(min: 66, ideal: 70)   // all six dots
            .customizationID("categories")
        } rows: {
            if !conversations.isEmpty {
                // Under the same date headings as below, filed by each conversation's newest message.
                ForEach(conversationDateGroups(conversations), id: \.title) { group in
                    Section(group.title, isExpanded: isExpanded(group.title)) {
                        ForEach(group.conversations) { conversation in
                            rows(for: conversation)
                        }
                    }
                }
            } else if isSortedByDate {
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
        .themeBackground(appearance.colors?.list)
        // macOS's alternating row stripes would clash with a theme's color, so a theme turns them off.
        .alternatingRowBackgrounds(appearance.colors == nil ? .automatic : .disabled)
        // Right-click menu and double-click; the same in both list styles.
        .contextMenu(forSelectionType: MailMessage.ID.self, menu: messageMenu, primaryAction: openMessages)
    }

    // The right-click menu. `ids` is the set of rows the menu applies to.
    @ViewBuilder
    private func messageMenu(for ids: Set<MailMessage.ID>) -> some View {
        let chosen = messages.filter { ids.contains($0.id) }
        if !chosen.isEmpty {
            Button("Open") { perform(.open, chosen) }
            Divider()
            if chosen.contains(where: { !$0.isRead }) {
                Button("Mark as Read") { perform(.markRead, chosen) }
            }
            if chosen.contains(where: \.isRead) {
                Button("Mark as Unread") { perform(.markUnread, chosen) }
            }
            if chosen.contains(where: { !$0.isFlagged }) {
                Button("Flag") { perform(.flag, chosen) }
            }
            Menu("Follow Up") {
                FollowUpMenuItems { perform(.followUp($0), chosen) }
            }
            Menu("Categorize") {
                CategorizeMenuItems(messages: chosen) { perform($0, chosen) }
            }
            if chosen.contains(where: \.isFlagged) {
                Button("Clear Flag") { perform(.clearFlag, chosen) }
            }
            Divider()
            let targets = moveTargets(chosen)
            Menu("Move To") {
                ForEach(targets) { group in
                    if group.isMessagesOwnAccount {
                        ForEach(group.folders) { folder in
                            Button(folder.displayName) { perform(.move(to: folder), chosen) }
                        }
                        Divider()
                    } else {
                        Menu(group.accountName) {
                            ForEach(group.folders) { folder in
                                Button(folder.displayName) { perform(.move(to: folder), chosen) }
                            }
                        }
                    }
                }
            }
            .disabled(targets.isEmpty)
            Divider()
            Button("Delete", role: .destructive) { perform(.delete, chosen) }
        }
    }

    // Double-click or Return: opens the messages in their own windows.
    private func openMessages(_ ids: Set<MailMessage.ID>) {
        perform(.open, messages.filter { ids.contains($0.id) })
    }

    // One message's row. Each row can be dragged; the payload is worked out when the drag starts.
    private func row(for message: MailMessage) -> some TableRowContent<MailMessage> {
        TableRow(message)
            .draggable(dragPayload(startingWith: message))
    }

    // A conversation's rows: just the message if it's on its own; otherwise its
    // newest message, with an arrow that shows the rest of the conversation under it.
    // `@TableRowBuilder` lets this function list rows, with an if/else between them.
    @TableRowBuilder<MailMessage>
    private func rows(for conversation: Conversation) -> some TableRowContent<MailMessage> {
        if conversation.messages.count == 1 {
            row(for: conversation.newest)
        } else {
            DisclosureTableRow(conversation.newest) {
                ForEach(conversation.messages.dropFirst()) { message in
                    row(for: message)
                }
            }
            .draggable(dragPayload(startingWith: conversation.newest))
        }
    }

    // The conversations, newest first, or oldest first if you clicked the
    // Received header to reverse the order.
    private var orderedConversations: [Conversation] {
        let conversations = Conversations.group(messages)
        return sortOrder.first?.order == .forward ? conversations.reversed() : conversations
    }

    // Conversations split into runs that share a date heading (from each one's newest message), in order.
    private func conversationDateGroups(_ conversations: [Conversation]) -> [(title: String, conversations: [Conversation])] {
        var groups: [(title: String, conversations: [Conversation])] = []
        for conversation in conversations {
            let title = DateHeading.title(for: conversation.newest.dateReceived)
            if groups.last?.title == title {
                groups[groups.count - 1].conversations.append(conversation)
            } else {
                groups.append((title, [conversation]))
            }
        }
        return groups
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

    // The short date shown on each row of the Comfortable list: the time for
    // today, "Yesterday", the weekday within the last week, otherwise the date.
    static func shortText(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if date >= today { return date.formatted(date: .omitted, time: .shortened) }   // e.g. "9:41 AM"
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), date >= weekAgo {
            return date.formatted(Date.FormatStyle(calendar: calendar).weekday(.wide))   // e.g. "Monday"
        }
        return date.formatted(date: .numeric, time: .omitted)   // e.g. "10/14/2026"
    }

    // The date in the Compact list's Received column, kept short like classic
    // Outlook's: the time for today, the short weekday and time within the last
    // week, otherwise the date with a two-digit year.
    static func compactText(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        if date >= today { return date.formatted(date: .omitted, time: .shortened) }   // e.g. "9:41 AM"
        let format = Date.FormatStyle(calendar: calendar)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today), date >= weekAgo {
            return date.formatted(format.weekday(.abbreviated).hour().minute())   // e.g. "Sat 4:53 PM"
        }
        return date.formatted(format.month(.defaultDigits).day().year(.twoDigits))   // e.g. "10/14/26"
    }
}
