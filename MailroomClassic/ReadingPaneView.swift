// The reading pane: shows the selected message's header (subject, sender,
// recipients, date), its attachments (each downloads when you open or save it),
// and its body, either formatted (HTML) or plain text. Shows a placeholder
// when nothing is selected.

import SwiftUI

struct ReadingPaneView: View {
    @Environment(MailStore.self) private var store

    // The `?` means "optional": there may be no message selected,
    // and its contents may still be downloading.
    let message: MailMessage?
    let openMessage: OpenMessage?
    let editDraft: (() -> Void)?   // set only when viewing the Drafts folder

    // Whether you clicked "Download Pictures" for this message. ContentView owns it
    // (and resets it for each new message) because printing needs to know too.
    @Binding var allowRemoteContent: Bool

    @State private var attachmentError: String?
    @State private var downloadingAttachmentID: MailAttachment.ID?   // shows a spinner on that button

    var body: some View {
        // `if let` unwraps the optional: the code inside only runs when
        // `message` actually holds a message.
        if let message {
            VStack(alignment: .leading, spacing: 0) {
                header(for: message)
                    .padding()

                if let openMessage {
                    if !openMessage.attachments.isEmpty {
                        attachmentBar(openMessage.attachments)
                    }
                    Divider()
                    messageBody(openMessage)
                } else {
                    Divider()
                    ProgressView()   // spinner while the message downloads
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: message.id) {
                attachmentError = nil
            }
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }

    private func header(for message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.subject)
                    .font(.title2)
                    .bold()
                    .textSelection(.enabled)
                if message.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                if let editDraft {
                    Button("Edit Draft", systemImage: "pencil", action: editDraft)
                        .disabled(openMessage == nil)
                }
            }
            Text(verbatim: "From: \(message.sender.formatted)")
            Text(verbatim: "To: \(message.toRecipients.map(\.formatted).joined(separator: ", "))")
                .foregroundStyle(.secondary)
            if !message.ccRecipients.isEmpty {
                Text(verbatim: "Cc: \(message.ccRecipients.map(\.formatted).joined(separator: ", "))")
                    .foregroundStyle(.secondary)
            }
            Text(message.dateReceived, format: .dateTime.weekday(.wide).month().day().year().hour().minute())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A row of buttons, one per attachment. Click to open; right-click to save.
    private func attachmentBar(_ attachments: [MailAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(attachments) { attachment in
                        Button {
                            download(attachment) { try AttachmentFiles.open($0, named: attachment.filename) }
                        } label: {
                            HStack(spacing: 4) {
                                if downloadingAttachmentID == attachment.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "paperclip")
                                }
                                // e.g. "report.pdf (1.2 MB)", or just the name if the size is unknown
                                Text(attachment.sizeText.map { "\(attachment.filename) (\($0))" } ?? attachment.filename)
                            }
                        }
                        .help("Click to open, or right-click to save")
                        .disabled(downloadingAttachmentID != nil)
                        .contextMenu {
                            Button("Open") { download(attachment) { try AttachmentFiles.open($0, named: attachment.filename) } }
                            Button("Save As…") { download(attachment) { try AttachmentFiles.saveWithPanel($0, named: attachment.filename) } }
                        }
                    }
                }
            }
            if let attachmentError {
                Text(attachmentError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder   // lets this function return different kinds of views from an if/else
    private func messageBody(_ openMessage: OpenMessage) -> some View {
        if let html = openMessage.html {
            if !allowRemoteContent && RemoteContentBlocker.hasRemoteContent(html) {
                // The classic Outlook privacy bar.
                HStack {
                    Image(systemName: "photo")
                    Text("To protect your privacy, pictures from the internet in this message were not downloaded.")
                    Spacer()
                    Button("Download Pictures") { allowRemoteContent = true }
                }
                .font(.callout)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.2))
            }
            HTMLMessageView(html: html, allowRemoteContent: allowRemoteContent)
        } else {
            ScrollView {
                Text(openMessage.plainText)
                    .textSelection(.enabled)   // lets you highlight and copy the text
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    // Downloads an attachment, then does something with the file (open or save it).
    // Any error shows under the attachment buttons.
    private func download(_ attachment: MailAttachment, then action: @escaping (Data) throws -> Void) {
        downloadingAttachmentID = attachment.id
        attachmentError = nil
        Task {
            defer { downloadingAttachmentID = nil }
            do {
                let data = try await store.data(for: attachment)
                try action(data)
            } catch {
                attachmentError = "Couldn't open “\(attachment.filename)”: \(FriendlyError.message(for: error))"
            }
        }
    }
}
