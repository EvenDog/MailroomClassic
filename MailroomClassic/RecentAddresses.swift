// Remembers email addresses you've used (people you've sent to, and senders
// of mail you've opened) so the To and Cc fields can suggest them as you type.
// Classic Outlook called this the "nickname cache". The list is kept in the
// app's settings on this Mac, most recently used first. Suggestions also
// include everyone in the Contacts app (see ContactsBook).

import Foundation

enum RecentAddresses {
    private static let storageKey = "recentAddresses"
    private static let maximumCount = 500
    private static let maximumSuggestions = 8

    // Every remembered address, most recent first.
    static func all() -> [MailAddress] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let addresses = try? JSONDecoder().decode([MailAddress].self, from: data) else { return [] }
        return addresses
    }

    // Moves these addresses to the front of the list (adding any that are new).
    // If one arrives without a name but we already knew the name, the name is kept.
    static func remember(_ addresses: [MailAddress]) {
        var list = all()
        for newAddress in addresses.reversed() where newAddress.address.contains("@") {
            let key = newAddress.address.lowercased()
            let known = list.first { $0.address.lowercased() == key }
            list.removeAll { $0.address.lowercased() == key }
            list.insert(MailAddress(name: newAddress.name ?? known?.name, address: newAddress.address), at: 0)
        }
        if let data = try? JSONEncoder().encode(Array(list.prefix(maximumCount))) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // Remembered addresses, then the rest of the Contacts app's, that match the
    // one being typed at the end of a To or Cc field: the email address, or any
    // word of the name, starts with what you typed.
    // Leaves out addresses already in the field.
    static func matches(for fieldText: String) -> [MailAddress] {
        let typing = split(fieldText).typing.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typing.isEmpty else { return [] }
        let alreadyInField = fieldText.lowercased()
        let recent = all()
        let recentKeys = Set(recent.map { $0.address.lowercased() })
        let fromContacts = ContactsBook.shared.addresses.filter { !recentKeys.contains($0.address.lowercased()) }
        let matching = (recent + fromContacts).filter { candidate in
            let nameWords = (candidate.name ?? "").lowercased().split(separator: " ")
            let startsWithTyped = candidate.address.lowercased().hasPrefix(typing)
                || nameWords.contains { $0.hasPrefix(typing) }
                || (candidate.name ?? "").lowercased().hasPrefix(typing)   // e.g. "sarah mi" matches "Sarah Miller"
            return startsWithTyped && !alreadyInField.contains(candidate.address.lowercased())
        }
        return Array(matching.prefix(maximumSuggestions))
    }

    // The field's new text if you pick `address`: what was typed before the last
    // comma stays, and the partly typed address is replaced with the full one.
    static func completing(_ fieldText: String, with address: MailAddress) -> String {
        let earlier = split(fieldText).earlier
        return (earlier.isEmpty ? "" : earlier + " ") + address.formatted + ", "
    }

    // Splits "a@x.com, sar" into the finished part ("a@x.com,") and the part being typed (" sar").
    private static func split(_ fieldText: String) -> (earlier: String, typing: String) {
        guard let separator = fieldText.lastIndex(where: { $0 == "," || $0 == ";" }) else {
            return ("", fieldText)
        }
        return (String(fieldText[...separator]), String(fieldText[fieldText.index(after: separator)...]))
    }
}
