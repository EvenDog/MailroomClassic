// The message body editor in the compose window. It supports formatting (bold,
// italic, underline, fonts, colors) through the Format menu, and converts what
// you wrote into HTML for sending. It always looks like white paper with black
// text, even in dark mode, so recipients see exactly what you typed. Spelling
// mistakes get a red underline as you type, and files dropped onto it are attached.

import AppKit
import SwiftUI

// Wraps AppKit's NSTextView (the editor TextEdit uses) for use in SwiftUI.
struct RichTextEditor: NSViewRepresentable {
    // NSAttributedString = text plus formatting (fonts, bold, colors) for each character.
    @Binding var text: NSAttributedString
    let onDropFiles: ([URL]) -> Void   // files dragged in from Finder, to attach

    static let defaultFont = NSFont(name: "Helvetica", size: 14) ?? .systemFont(ofSize: 14)
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: defaultFont,
        .foregroundColor: NSColor.black,
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // A text view inside a scroll view, set up the way AppKit's own
        // `NSTextView.scrollableTextView()` does it, but using our AttachingTextView.
        let textView = AttachingTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]   // as wide as the window; grows downwards as you type
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        scrollView.appearance = NSAppearance(named: .aqua)   // always light mode, like paper

        textView.onDropFiles = onDropFiles
        textView.isContinuousSpellCheckingEnabled = true   // red underlines under misspelled words
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
        textView.updateDragTypeRegistration()   // start accepting the drag types listed in AttachingTextView
        return scrollView
    }

    // Called when SwiftUI redraws; only replaces the text if it was changed from outside.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? AttachingTextView else { return }
        textView.onDropFiles = onDropFiles
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

    // The editor itself: an ordinary NSTextView, except that files dropped onto
    // it are handed to `onDropFiles` (to attach) instead of being typed in as text.
    // `override` replaces NSTextView's own version of a method with ours.
    final class AttachingTextView: NSTextView {
        var onDropFiles: (([URL]) -> Void)?

        // The files being dragged, if what's being dragged is files from Finder.
        private func draggedFiles(_ drag: NSDraggingInfo) -> [URL] {
            drag.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        // Which kinds of dragged things the view accepts: the usual ones, plus files.
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes + [.fileURL]
        }

        // While files are dragged over it, the pointer shows a green "+" (copy).
        override func draggingEntered(_ drag: NSDraggingInfo) -> NSDragOperation {
            draggedFiles(drag).isEmpty ? super.draggingEntered(drag) : .copy
        }

        override func draggingUpdated(_ drag: NSDraggingInfo) -> NSDragOperation {
            draggedFiles(drag).isEmpty ? super.draggingUpdated(drag) : .copy
        }

        override func performDragOperation(_ drag: NSDraggingInfo) -> Bool {
            let files = draggedFiles(drag)
            guard !files.isEmpty else { return super.performDragOperation(drag) }   // e.g. dragged text
            onDropFiles?(files)
            return true
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
