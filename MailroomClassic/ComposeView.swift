// The compose window, used for New Email, Reply, Reply All and Forward:
// From / To / Cc / Subject fields on top, attached files under them, the
// message body below, and Send and Attach buttons in the toolbar. The window
// closes itself once the email is sent.

import SwiftUI

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss   // closes this window

    @State var draft: ComposeDraft
    @State private var isSending = false
    @State private var isChoosingAttachments = false
    @State private var errorMessage: String?

    private var canSend: Bool {
        !isSending && draft.accountID != nil && !draft.to.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("From:", selection: $draft.accountID) {
                    ForEach(store.accounts) { account in
                        // `Optional(...)` because the selection's type is `UUID?`.
                        Text(verbatim: "\(account.senderName) <\(account.emailAddress)>")
                            .tag(Optional(account.id))
                    }
                }
                TextField("To:", text: $draft.to, prompt: Text("Separate addresses with commas"))
                TextField("Cc:", text: $draft.cc)
                TextField("Subject:", text: $draft.subject)
            }
            .formStyle(.columns)   // labels in a column on the left, like Outlook
            .padding()

            if !draft.attachmentURLs.isEmpty {
                attachmentList
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            TextEditor(text: $draft.body)
                .font(.body)
                .padding(8)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(draft.subject.isEmpty ? "Untitled Message" : draft.subject)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Send", systemImage: "paperplane") {
                    Task { await send() }
                }
                .help("Send")
                .keyboardShortcut(.return, modifiers: .command)   // ⌘Return sends
                .disabled(!canSend)
            }
            ToolbarItem {
                Button("Attach File", systemImage: "paperclip") {
                    isChoosingAttachments = true
                }
                .help("Attach File (⇧⌘A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
        // The standard "choose files" window. `.item` means any kind of file.
        .fileImporter(isPresented: $isChoosingAttachments, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                draft.attachmentURLs += urls
            }
        }
        .onAppear {
            // New Email from the menu doesn't pick an account, so default to the first one.
            if draft.accountID == nil {
                draft.accountID = store.accounts.first?.id
            }
        }
    }

    // One row of buttons, one per attached file; clicking one removes it.
    private var attachmentList: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(draft.attachmentURLs, id: \.self) { url in
                    Button {
                        draft.attachmentURLs.removeAll { $0 == url }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Text(url.lastPathComponent)
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Click to remove this attachment")
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        do {
            try await store.send(draft)
            dismiss()
        } catch {
            errorMessage = "Couldn't send: \(error.localizedDescription)"
        }
        isSending = false
    }
}
