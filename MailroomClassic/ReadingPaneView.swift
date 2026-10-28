// The reading pane: shows the selected message's header (subject, sender with
// their photo from Contacts and an Add to Contacts button if they aren't there,
// recipients, date), its attachments (each downloads when you open or save it),
// and its body, either formatted (HTML) or plain text. Shows a placeholder
// when nothing is selected. Pictures from the internet stay blocked until you
// click Download Pictures (or Always from This Sender). The text-size buttons (⌘+ and ⌘−) make the message
// bigger or smaller; the size is remembered for every message.

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

    // How big message text is shown, in percent (100 = normal). Saved, so it stays the same next launch.
    @AppStorage("messageTextZoomPercent") private var zoomPercent = 100
    private static let zoomRange = 50...300

    @State private var attachmentError: String?
    @State private var downloadingAttachmentID: MailAttachment.ID?   // shows a spinner on that button
    @State private var contactsError: String?   // if "Add to Contacts" failed

    // For the in-between themes' reading pane color (see AppAppearance).
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some View {
        pane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appearance.colors?.reading ?? .clear)
    }

    // The message, or a placeholder when none is selected.
    @ViewBuilder   // lets this property return different kinds of views from an if/else
    private var pane: some View {
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
                    messageBody(openMessage, of: message)
                } else {
                    Divider()
                    ProgressView()   // spinner while the message downloads
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onChange(of: message.id) {
                attachmentError = nil
                contactsError = nil
            }
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }

    // The sender's photo from Contacts (or their initials in a circle), then their
    // name, address and the date, the subject in large type, and who else it was sent to.
    private func header(for message: MailMessage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            senderPicture(for: message.sender)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)   // the name is right next to it
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.senderDisplayName)
                        .font(.headline)
                    // The address too, so a fake "From" name is easy to spot.
                    if message.sender.name != nil {
                        Text(verbatim: "<\(message.sender.address)>")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    addToContactsButton(for: message.sender)
                    Spacer()
                    Text(message.dateReceived, format: .dateTime.weekday(.abbreviated).month().day().year().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                HStack(alignment: .firstTextBaseline) {
                    Text(message.subject)
                        .font(.title2)
                        .bold()
                        .textSelection(.enabled)
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundStyle(.red)
                    }
                    if let due = store.followUp(for: message)?.dueDate {
                        Text(FollowUps.dueText(for: due))
                            .foregroundStyle(FollowUps.isDueNow(due) ? .red : .secondary)
                    }
                    Spacer()
                    textSizeButtons
                    if let editDraft {
                        Button("Edit Draft", systemImage: "pencil", action: editDraft)
                            .disabled(openMessage == nil)
                    }
                }
                Text(verbatim: recipientsLine(for: message))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !message.categories.isEmpty {
                    categoryLabels(message.categories)
                }
                if let contactsError {
                    Text(contactsError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // "To: Sarah Miller <sarah@example.com> · Cc: tom@example.com"
    private func recipientsLine(for message: MailMessage) -> String {
        var parts = ["To: " + message.toRecipients.map(\.formatted).joined(separator: ", ")]
        if !message.ccRecipients.isEmpty {
            parts.append("Cc: " + message.ccRecipients.map(\.formatted).joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    // The message's color categories, each as a small rounded label with its name.
    private func categoryLabels(_ categories: Set<MailCategory>) -> some View {
        HStack(spacing: 6) {
            ForEach(categories.sorted(), id: \.self) { category in
                Text(category.name)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(category.color.opacity(0.25), in: Capsule())
                    .overlay(Capsule().stroke(category.color, lineWidth: 1))
            }
        }
    }

    // The sender's photo from Contacts, cut into a circle, or their initials if there isn't one.
    @ViewBuilder
    private func senderPicture(for sender: MailAddress) -> some View {
        if let photo = ContactsBook.shared.photo(for: sender.address) {
            Image(nsImage: photo)
                .resizable()
                .scaledToFill()   // fills the circle, trimming the edges if it isn't square
                .clipShape(Circle())
        } else {
            Text(initials(of: sender))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor.opacity(0.18), in: Circle())
        }
    }

    // A small "add person" button next to a sender who isn't in Contacts yet.
    // (Hidden if Mailroom isn't allowed to use Contacts.)
    @ViewBuilder
    private func addToContactsButton(for sender: MailAddress) -> some View {
        let contacts = ContactsBook.shared
        if contacts.hasAccess && !contacts.contains(sender.address) {
            Button("Add to Contacts", systemImage: "person.crop.circle.badge.plus") {
                do {
                    try contacts.add(sender)
                } catch {
                    contactsError = "Couldn't add \(sender.address) to Contacts: \(error.localizedDescription)"
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Add \(sender.name ?? sender.address) to Contacts")
        }
    }

    // Up to two letters for the circle: "Sarah Chen" → "SC", "news@shop.com" → "N".
    private func initials(of address: MailAddress) -> String {
        let words = (address.name ?? address.address).split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        let letters = (address.name == nil ? words.prefix(1) : words.prefix(2)).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    // Smaller / bigger text. The keyboard shortcuts work while this window is in front.
    private var textSizeButtons: some View {
        HStack(spacing: 2) {
            Button("Smaller Text", systemImage: "textformat.size.smaller") {
                zoomPercent = max(Self.zoomRange.lowerBound, zoomPercent - 10)
            }
            .help("Make the message text smaller (⌘−)")
            .keyboardShortcut("-")
            .disabled(zoomPercent <= Self.zoomRange.lowerBound)
            Button("Bigger Text", systemImage: "textformat.size.larger") {
                zoomPercent = min(Self.zoomRange.upperBound, zoomPercent + 10)
            }
            .help("Make the message text bigger (⌘+)")
            .keyboardShortcut("+")
            .disabled(zoomPercent >= Self.zoomRange.upperBound)
        }
        .labelStyle(.iconOnly)   // just the icons, no words
        .buttonStyle(.borderless)
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
    private func messageBody(_ openMessage: OpenMessage, of message: MailMessage) -> some View {
        if let html = openMessage.html {
            if !allowRemoteContent && RemoteContentBlocker.hasRemoteContent(html) {
                // The privacy bar, in a rounded grey box.
                HStack {
                    Image(systemName: "photo")
                    Text("Pictures from the internet are hidden to protect your privacy.")
                    Spacer()
                    Button("Load Pictures") { allowRemoteContent = true }
                    // Not offered in Junk, where the list doesn't apply (see PictureSenders).
                    if store.folder(of: message)?.role != .junk {
                        Button("Always from This Sender") {
                            PictureSenders.add(message.sender.address)
                            allowRemoteContent = true
                        }
                        .buttonStyle(.borderedProminent)   // filled with the accent color
                        .help("Always load pictures in emails from \(message.sender.address). Settings → Accounts lists these senders.")
                    }
                }
                .font(.callout)
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            HTMLMessageView(html: html, allowRemoteContent: allowRemoteContent, zoom: Double(zoomPercent) / 100)
        } else {
            ScrollView {
                Text(openMessage.plainText)
                    .font(.system(size: 13 * Double(zoomPercent) / 100))   // 13 points is the normal size
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
