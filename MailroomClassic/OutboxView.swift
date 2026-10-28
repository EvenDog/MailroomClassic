// The Outbox (selected in the sidebar): every email waiting to be sent later,
// soonest first, with who it's to, its subject and when it goes. Each has
// Edit (reopens it to change; it leaves the Outbox until you send or schedule it
// again), Send Now, and Delete (after asking).

import SwiftUI

struct OutboxView: View {
    @Environment(MailStore.self) private var store

    @State private var emailToDelete: ScheduledEmail?
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            if store.scheduledEmails.isEmpty {
                ContentUnavailableView("The Outbox Is Empty", systemImage: "clock",
                                       description: Text("Emails you schedule with Send Later wait here until it's time to send them."))
            } else {
                List {
                    ForEach(store.scheduledEmails) { scheduled in
                        row(for: scheduled)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)   // shows the column's color (or a theme's) behind it
            }
            Text("Scheduled emails are only sent while Mailroom Classic is open. If it's closed (or the Mac is asleep) when one is due, it goes out as soon as the app is open again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .confirmationDialog("Delete “\(emailToDelete?.draft.subject ?? "")” without sending it?",
                            isPresented: $isConfirmingDelete, presenting: emailToDelete) { scheduled in
            Button("Delete", role: .destructive) { store.deleteScheduled(scheduled) }
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    private func row(for scheduled: ScheduledEmail) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scheduled.draft.to)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(scheduled.draft.subject.isEmpty ? "(No Subject)" : scheduled.draft.subject)
                    .lineLimit(1)
                Label(scheduled.sendAt.formatted(date: .complete, time: .shortened), systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { store.editScheduled(scheduled) }
                .help("Opens it to change. It leaves the Outbox until you send or schedule it again.")
            Button("Send Now") { Task { await store.sendScheduledNow(scheduled) } }
            Button("Delete") {
                emailToDelete = scheduled
                isConfirmingDelete = true
            }
        }
        .padding(.vertical, 4)
    }
}
