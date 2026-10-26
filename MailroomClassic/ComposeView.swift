// The compose window, used for New Email, Reply, Reply All, Forward and editing
// drafts: From / To / Cc / Subject fields on top, attached files under them, a
// formatted message body below, and Send, Save Draft and Attach buttons in the
// toolbar. The window closes itself once the email is sent.

import SwiftUI

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss   // closes this window

    @State private var draft: ComposeDraft
    @State private var messageText: NSAttributedString   // the message body, with formatting
    @State private var isWorking = false
    @State private var isChoosingAttachments = false
    @State private var errorMessage: String?
    @State private var draftSavedAt: Date?

    // A custom init so the editor can start with the draft's text.
    // `_draft` and `_messageText` are the @State wrappers themselves, which is how you
    // give @State properties their starting values from an init.
    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
        _messageText = State(initialValue: RichTextEditor.initialText(html: draft.htmlBody, plain: draft.body))
    }

    private var sendingAccount: AccountSettings? {
        store.accounts.first { $0.id == draft.accountID }
    }

    private var canSend: Bool {
        !isWorking && draft.accountID != nil && !draft.to.trimmingCharacters(in: .whitespaces).isEmpty
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
            } else if let draftSavedAt {
                Text("Draft saved at \(draftSavedAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            RichTextEditor(text: $messageText)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(draft.subject.isEmpty ? "Untitled Message" : draft.subject)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Send", systemImage: "paperplane") {
                    Task { await send() }
                }
                .help("Send (⌘Return)")
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
            }
            ToolbarItemGroup {
                Button("Save Draft", systemImage: "square.and.arrow.down") {
                    Task { await saveDraft() }
                }
                .help("Save Draft (⌘S)")
                .keyboardShortcut("s")
                .disabled(isWorking || draft.accountID == nil)
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

    // Copies the editor's text into the draft, as plain text and as HTML.
    private func captureBody() {
        draft.body = messageText.string
        draft.htmlBody = RichTextEditor.html(from: messageText)
    }

    private func send() async {
        isWorking = true
        errorMessage = nil
        captureBody()
        do {
            try await store.send(draft)
            dismiss()
        } catch {
            errorMessage = "Couldn't send: \(FriendlyError.message(for: error, server: sendingAccount?.smtpHost))"
        }
        isWorking = false
    }

    private func saveDraft() async {
        isWorking = true
        errorMessage = nil
        captureBody()
        do {
            draft.savedDraftUID = try await store.saveDraft(draft)
            draftSavedAt = Date()
        } catch {
            errorMessage = "Couldn't save the draft: \(FriendlyError.message(for: error, server: sendingAccount?.imapHost))"
        }
        isWorking = false
    }
}
