// Automatic updates, using Sparkle (github.com/sparkle-project/Sparkle), the updater most
// independent Mac apps use. About once a day it reads the list of versions (appcast.xml
// in the GitHub repo); if there's a newer one, it shows what's new and offers to install
// it, then relaunches. Every update must be signed with Mailroom Classic's private key
// (kept in the developer's Keychain), so nobody else can slip in a fake update.
// Sparkle's settings (where the list is, the public key) are in MailroomClassic-Info.plist.

import Combine
import Sparkle
import SwiftUI

// Mailroom Classic → Check for Updates…. Built the way Sparkle's documentation shows:
// a small helper object tracks whether a check can start, so the menu item is greyed
// out while one is already running.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var model: CheckForUpdatesModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        model = CheckForUpdatesModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!model.canCheckForUpdates)
    }
}

// Copies Sparkle's `canCheckForUpdates` into a property SwiftUI can watch.
// (`ObservableObject` + `@Published` is SwiftUI's older way of watching an object;
// Sparkle's example uses it because Sparkle reports changes the Objective-C way.)
private final class CheckForUpdatesModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        // `publisher(for:)` sends each new value of the property; `assign` stores it in ours.
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
