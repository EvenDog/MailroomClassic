// Makes a compose window ask "Do you want to save changes?" before it closes,
// like Outlook does for an email you haven't sent. SwiftUI has no built-in way
// to stop a window from closing, so this reaches down to the AppKit window
// (NSWindow) underneath. Add it to a view with `.background(WindowCloseGuard(...))`.

import AppKit
import SwiftUI

struct WindowCloseGuard: NSViewRepresentable {
    let hasUnsavedChanges: Bool
    let save: () async -> Bool   // saves the draft; returns whether that worked

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // An invisible view whose only job is to find out which window it's in.
    func makeNSView(context: Context) -> WindowFinderView {
        let view = WindowFinderView()
        let coordinator = context.coordinator
        view.onMoveToWindow = { [weak coordinator] window in coordinator?.watch(window) }
        return view
    }

    // Keeps the coordinator up to date each time SwiftUI redraws.
    func updateNSView(_ view: WindowFinderView, context: Context) {
        context.coordinator.hasUnsavedChanges = hasUnsavedChanges
        context.coordinator.save = save
    }

    final class WindowFinderView: NSView {
        var onMoveToWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onMoveToWindow?(window) }
        }
    }

    // Becomes the window's "delegate": the object AppKit asks things like
    // "may this window close?". SwiftUI already had a delegate there, which
    // it needs for everything else, so every other question is passed on to it.
    final class Coordinator: NSObject, NSWindowDelegate {
        var hasUnsavedChanges = false {
            // Also shows the classic "unsaved" dot in the window's red close button.
            didSet { window?.isDocumentEdited = hasUnsavedChanges }
        }
        var save: () async -> Bool = { true }
        private weak var window: NSWindow?
        private weak var swiftUIDelegate: NSWindowDelegate?

        func watch(_ window: NSWindow) {
            guard window.delegate !== self else { return }
            self.window = window
            swiftUIDelegate = window.delegate
            window.delegate = self
            window.isDocumentEdited = hasUnsavedChanges
        }

        // MAGIC: these two methods are Objective-C "message forwarding". AppKit
        // first asks whether the delegate `responds(to:)` a question; we say yes if
        // SwiftUI's delegate does, and `forwardingTarget(for:)` then hands every
        // question we don't answer ourselves over to SwiftUI's delegate.
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || swiftUIDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            swiftUIDelegate
        }

        // Called when you click the close button or press ⌘W. Returning false keeps the window open.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard hasUnsavedChanges else {
                return swiftUIDelegate?.windowShouldClose?(sender) ?? true
            }
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes?"
            alert.informativeText = "This message hasn't been sent. Saving puts a copy in your Drafts folder."
            alert.addButton(withTitle: "Save")         // the first button is the default (Return)
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")       // a button titled "Cancel" also answers Esc
            // A "sheet" is an alert that slides down from the top of this window.
            alert.beginSheetModal(for: sender) { response in
                switch response {
                case .alertFirstButtonReturn:
                    Task {
                        // If saving fails, the window stays open and shows the error.
                        if await self.save() { self.closeWithoutAsking(sender) }
                    }
                case .alertSecondButtonReturn:
                    self.closeWithoutAsking(sender)
                default:
                    break   // Cancel: keep writing
                }
            }
            return false   // don't close yet; the alert's answer decides
        }

        private func closeWithoutAsking(_ window: NSWindow) {
            hasUnsavedChanges = false
            window.close()   // `close()` (unlike the close button) doesn't ask windowShouldClose again
        }
    }
}
