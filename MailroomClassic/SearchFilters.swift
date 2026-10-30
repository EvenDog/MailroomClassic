// The search filters: From, Date and Has attachments, in a bar that opens above the
// message list (the filter button next to the Comfortable/Compact buttons, or any search).
// They narrow down whatever the list shows: a folder, All Inboxes, a Search Folder or
// search results. So "everything from Alice in the last 30 days" works with the search
// box left empty; choose All Folders in the bar to look through every folder.

import SwiftUI

struct SearchFilters: Equatable {
    var from = ""   // part of the sender's name or address
    var date = DateFilter.anyTime
    var customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    var customEnd = Date.now
    var hasAttachments = false

    // True if any filter is set (so the list is being narrowed down).
    var isActive: Bool {
        !trimmedFrom.isEmpty || date != .anyTime || hasAttachments
    }

    private var trimmedFrom: String {
        from.trimmingCharacters(in: .whitespaces)
    }

    // Whether a message passes every filter that's set.
    func includes(_ message: MailMessage) -> Bool {
        if !trimmedFrom.isEmpty,
           !(message.sender.name ?? "").localizedCaseInsensitiveContains(trimmedFrom),
           !message.sender.address.localizedCaseInsensitiveContains(trimmedFrom) {
            return false
        }
        if hasAttachments && !message.hasAttachments {
            return false
        }
        if let range = date.range(customStart: customStart, customEnd: customEnd), !range.contains(message.dateReceived) {
            return false
        }
        return true
    }
}

// The Date filter's choices.
enum DateFilter: String, CaseIterable {
    case anyTime = "Any time"
    case today = "Today"
    case last7Days = "Last 7 days"
    case last30Days = "Last 30 days"
    case thisYear = "This year"
    case custom = "Custom range"

    // The dates a message must have arrived between, or nil for Any time.
    func range(customStart: Date, customEnd: Date) -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let now = Date.now
        let start: Date? = switch self {
        case .anyTime: nil
        case .today: calendar.startOfDay(for: now)
        case .last7Days: calendar.date(byAdding: .day, value: -7, to: now)
        case .last30Days: calendar.date(byAdding: .day, value: -30, to: now)
        case .thisYear: calendar.dateInterval(of: .year, for: now)?.start
        case .custom: calendar.startOfDay(for: min(customStart, customEnd))
        }
        guard let start else { return nil }
        if self == .custom {
            // To the end of the last chosen day (the start of the next day), whichever order they were picked in.
            let lastDay = calendar.startOfDay(for: max(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? now
            return start...end
        }
        return start...now.addingTimeInterval(24 * 60 * 60)   // a day ahead, for senders whose clocks run fast
    }
}

// The bar of filter controls above the message list.
struct SearchFilterBar: View {
    @Binding var filters: SearchFilters
    // Where to look: the shown folder, or all folders. The same choice as the one under
    // the search box, so they always agree.
    @Binding var scope: SearchScope
    let thisFolderName: String   // "This Folder", "All Inboxes" or a Search Folder's name

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Look in", selection: $scope) {
                    Text(thisFolderName).tag(SearchScope.thisFolder)
                    Text("All Folders").tag(SearchScope.allFolders)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button("Clear") { filters = SearchFilters() }
                    .disabled(!filters.isActive)
            }
            HStack(spacing: 10) {
                TextField("From", text: $filters.from, prompt: Text("From: name or address"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 110, maxWidth: 200)
                Picker("Date", selection: $filters.date) {
                    ForEach(DateFilter.allCases, id: \.self) { choice in
                        Text(choice.rawValue)
                    }
                }
                .fixedSize()   // only as wide as the chosen item
                Toggle("Has attachments", isOn: $filters.hasAttachments)   // a checkbox on the Mac
                Spacer()
            }
            if filters.date == .custom {
                HStack {
                    DatePicker("From", selection: $filters.customStart, displayedComponents: .date)
                    DatePicker("to", selection: $filters.customEnd, displayedComponents: .date)
                    Spacer()
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
