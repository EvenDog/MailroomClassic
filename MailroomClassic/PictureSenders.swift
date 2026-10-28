// The senders whose emails always show pictures from the internet straight away,
// like classic Outlook's Safe Senders list. Everyone else's stay blocked until you
// click Download Pictures (senders use those pictures to tell when you read mail).
// Pictures in the Junk folder stay blocked even for these senders, since junk mail
// often fakes its From address. The list is kept in the app's settings on this Mac.

import Foundation

enum PictureSenders {
    // The setting holding the list: one lowercase address per line. Views that show
    // the list read it with @AppStorage, so they update when it changes.
    static let storageKey = "pictureSenders"

    // Every address on the list, A to Z.
    static func all() -> [String] {
        (UserDefaults.standard.string(forKey: storageKey) ?? "").split(separator: "\n").map(String.init)
    }

    static func add(_ address: String) {
        let address = address.lowercased()
        guard address.contains("@"), !all().contains(address) else { return }
        save(all() + [address])
    }

    static func remove(_ address: String) {
        save(all().filter { $0 != address.lowercased() })
    }

    // Whether a message's pictures should download as soon as it's shown.
    static func picturesAllowed(for message: MailMessage, in folder: MailFolder?) -> Bool {
        folder?.role != .junk && all().contains(message.sender.address.lowercased())
    }

    private static func save(_ addresses: [String]) {
        UserDefaults.standard.set(addresses.sorted().joined(separator: "\n"), forKey: storageKey)
    }
}
