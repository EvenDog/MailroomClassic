// The message body editor in the compose window. It supports formatting (bold,
// italic, underline, fonts, colors) through the Format menu, and converts what
// you wrote into HTML for sending. It always looks like white paper with black
// text, even in dark mode, so recipients see exactly what you typed.

import AppKit
import SwiftUI

// Wraps AppKit's NSTextView (the editor TextEdit uses) for use in SwiftUI.
struct RichTextEditor: NSViewRepresentable {
    // NSAttributedString = text plus formatting (fonts, bold, colors) for each character.
    @Binding var text: NSAttributedString

    static let defaultFont = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: defaultFont,
        .foregroundColor: NSColor.black,
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.appearance = NSAppearance(named: .aqua)   // always light mode, like paper
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true          // Format → Show Fonts works
        textView.importsGraphics = false       // attachments go through Attach File instead
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.typingAttributes = Self.defaultAttributes
        textView.textStorage?.setAttributedString(text)
        textView.delegate = context.coordinator
        return scrollView
    }

    // Called when SwiftUI redraws; only replaces the text if it was changed from outside.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if !textView.attributedString().isEqual(to: text) {
            textView.textStorage?.setAttributedString(text)
        }
    }

    // Copies each change you type back into the SwiftUI `text` binding.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<NSAttributedString>

        init(text: Binding<NSAttributedString>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.attributedString()
        }
    }

    // MARK: - Converting to and from HTML

    // The starting text for the editor: the formatted version if there is one,
    // otherwise the plain text in the default font.
    static func initialText(html: String?, plain: String) -> NSAttributedString {
        if let html, let formatted = NSAttributedString(html: Data(html.utf8), documentAttributes: nil) {
            return formatted
        }
        return NSAttributedString(string: plain, attributes: defaultAttributes)
    }

    // Converts the edited text into an HTML document to send.
    static func html(from text: NSAttributedString) -> String? {
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let data = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: options) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
