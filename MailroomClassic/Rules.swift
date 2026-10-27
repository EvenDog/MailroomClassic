// Rules, like classic Outlook's "Rules and Alerts": "when a message arrives in
// the Inbox and its sender or subject contains some text, move it to a folder".
// MailStore runs them on new Inbox mail after each check (and on everything in
// the Inbox with Run Rules Now); Settings → Rules is where you make them.

import Foundation

struct MailRule: Codable, Identifiable, Hashable {
    // Which part of a message the rule looks at.
    enum Field: String, Codable, CaseIterable {
        case sender      // the sender's name or address
        case subject
        case recipients  // any To or Cc recipient's name or address

        var label: String {
            switch self {
            case .sender: "From"
            case .subject: "Subject"
            case .recipients: "To or Cc"
            }
        }
    }

    var id = UUID()
    var field: Field
    var text: String
    var destinationFolderID: MailFolder.ID   // includes the account (see MailFolder.id)

    // Whether this rule applies to a message. Ignores capitals, so "golf" matches "Golf Genius".
    func matches(_ message: MailMessage) -> Bool {
        let candidates = switch field {
        case .sender: [message.sender.name ?? "", message.sender.address]
        case .subject: [message.subject]
        case .recipients: (message.toRecipients + message.ccRecipients).flatMap { [$0.name ?? "", $0.address] }
        }
        return candidates.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

// Saves and loads the rules between launches, in UserDefaults like the accounts.
enum RuleStorage {
    private static let rulesKey = "rules"

    // Returns the saved rules, or an empty list if there are none yet.
    static func loadRules() -> [MailRule] {
        guard let data = UserDefaults.standard.data(forKey: rulesKey) else { return [] }
        return (try? JSONDecoder().decode([MailRule].self, from: data)) ?? []
    }

    static func saveRules(_ rules: [MailRule]) {
        let data = try? JSONEncoder().encode(rules)
        UserDefaults.standard.set(data, forKey: rulesKey)
    }
}
