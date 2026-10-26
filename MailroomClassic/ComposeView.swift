// The compose window, used for New Email, Reply, Reply All, Forward and editing
// drafts: From / To / Cc / Subject fields on top, attached files under them, a
// formatted message body below, and Send, Save Draft and Attach buttons in the
// toolbar. The To and Cc fields suggest addresses you've used before, new
// emails start with your signature, and closing an unsent email asks whether
// to save it. The window closes itself once the email is sent.

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
    // What the window held when it opened or was last saved, to tell whether
    // anything has changed since. Nil until the window first appears.
    @State private var savedSnapshot: Snapshot?

    private struct Snapshot: Equatable {
        var accountID: UUID?
        var to, cc, subject, body: String
        var attachmentURLs: [URL]
    }

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

    private var currentSnapshot: Snapshot {
        // Only the text is compared, so a formatting-only change (e.g. making a word bold) doesn't count.
        Snapshot(accountID: draft.accountID, to: draft.to, cc: draft.cc, subject: draft.subject,
                 body: messageText.string, attachmentURLs: draft.attachmentURLs)
    }

    private var hasUnsavedChanges: Bool {
        savedSnapshot != nil && currentSnapshot != savedSnapshot
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
                    .textInputSuggestions { addressSuggestions(for: draft.to) }
                TextField("Cc:", text: $draft.cc)
                    .textInputSuggestions { addressSuggestions(for: draft.cc) }
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
            guard savedSnapshot == nil else { return }   // only the first time the window appears
            // New Email from the menu doesn't pick an account, so default to the first one.
            if draft.accountID == nil {
                draft.accountID = store.accounts.first?.id
            }
            addSignature()
            savedSnapshot = currentSnapshot
        }
        .background(WindowCloseGuard(hasUnsavedChanges: hasUnsavedChanges) { await saveDraft() })
    }

    // The drop-down list under To or Cc while you type. Picking a suggestion
    // replaces the partly typed address with the full one.
    private func addressSuggestions(for fieldText: String) -> some View {
        ForEach(RecentAddresses.matches(for: fieldText), id: \.self) { address in
            Text(address.formatted)
                .textInputCompletion(RecentAddresses.completing(fieldText, with: address))
        }
    }

    // Puts the account's signature at the top of a new email, reply or forward
    // (so in a reply it sits above the quoted original). A saved draft already has its own.
    private func addSignature() {
        guard draft.savedDraftUID == nil,
              let signature = sendingAccount?.signature, !signature.isEmpty else { return }
        let withSignature = NSMutableAttributedString(string: "\n\n" + signature, attributes: RichTextEditor.defaultAttributes)
        withSignature.append(messageText)
        messageText = withSignature
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
            savedSnapshot = currentSnapshot   // sent, so closing shouldn't ask to save
            dismiss()
        } catch {
            errorMessage = "Couldn't send: \(FriendlyError.message(for: error, server: sendingAccount?.smtpHost))"
        }
        isWorking = false
    }

    // Saves to the Drafts folder. Returns whether it worked (the close prompt needs to know).
    // `@discardableResult` lets the Save Draft button ignore that answer without a warning.
    @discardableResult
    private func saveDraft() async -> Bool {
        isWorking = true
        errorMessage = nil
        captureBody()
        defer { isWorking = false }   // `defer` runs this line on the way out, whichever `return` is used
        do {
            draft.savedDraftUID = try await store.saveDraft(draft)
            draftSavedAt = Date()
            savedSnapshot = currentSnapshot
            return true
        } catch {
            errorMessage = "Couldn't save the draft: \(FriendlyError.message(for: error, server: sendingAccount?.imapHost))"
            return false
        }
    }
}
