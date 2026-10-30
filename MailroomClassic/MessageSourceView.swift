// View → Message Source (⌥⌘U): a window showing the complete original email,
// exactly as the server keeps it: every header (who sent it, the servers it passed
// through, spam checks), then the body and attachments in their email encoding.
// Handy for working out where an email really came from. It's downloaded fresh
// when the window opens, and isn't marked as read.

import AppKit
import SwiftUI

struct MessageSourceView: View {
    @Environment(MailStore.self) private var store
    let messageID: MailMessage.ID

    @State private var source: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let source {
                SourceTextView(text: source)
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load the source", systemImage: "exclamationmark.triangle",
                                       description: Text(errorMessage))
            } else {
                ProgressView("Downloading the original email…")
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .navigationTitle(windowTitle)
        .toolbar {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source ?? "", forType: .string)
            }
            .help("Copy the whole source")
            .disabled(source == nil)
        }
        .task {
            do {
                source = try await store.rawSource(ofMessageID: messageID)
            } catch {
                errorMessage = FriendlyError.message(for: error, server: nil)
            }
        }
    }

    // "Source of “Lunch?”" if the message is in the list, otherwise just "Message Source".
    private var windowTitle: String {
        guard let message = store.messages.first(where: { $0.id == messageID }) else { return "Message Source" }
        return "Source of “\(message.subject)”"
    }
}

// A read-only, scrollable text box in a fixed-width font. SwiftUI's own Text gets
// very slow with megabytes of text, so this wraps AppKit's NSTextView instead.
private struct SourceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        // `scrollableTextView()` gives a text view already set up inside a scroll view.
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView   // always an NSTextView here
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}
