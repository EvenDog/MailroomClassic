// Rules, like classic Outlook's "Rules and Alerts": "when a message arrives in
// the Inbox and its sender or subject contains some text, move it to a folder"
// (or mark it as read, flag it, or delete it).
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

    // What a rule does to the messages it matches.
    enum Action: String, Codable, CaseIterable {
        case move       // to destinationFolderID, in the same account
        case markRead
        case flag
        case delete     // to the account's Trash

        var label: String {
            switch self {
            case .move: "Move it to a folder"
            case .markRead: "Mark it as read"
            case .flag: "Flag it"
            case .delete: "Delete it"
            }
        }
    }

    var id = UUID()
    var field: Field
    var text: String
    var action: Action = .move
    // Only used by Move rules. Includes the account (see MailFolder.id).
    var destinationFolderID: MailFolder.ID?

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

// Reading a saved rule. Swift would write this automatically, but it would fail on
// rules saved before rules had actions (they have no "action"), so it's written
// out here to treat those as Move rules. Being in an extension keeps the automatic
// MailRule(field:text:…) initializer working.
extension MailRule {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        field = try container.decode(Field.self, forKey: .field)
        text = try container.decode(String.self, forKey: .text)
        action = try container.decodeIfPresent(Action.self, forKey: .action) ?? .move
        destinationFolderID = try container.decodeIfPresent(MailFolder.ID.self, forKey: .destinationFolderID)
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
