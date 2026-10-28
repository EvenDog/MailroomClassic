// Groups messages into conversations (an email plus the replies to it), for
// View → Show as Conversations, like classic Outlook's "Arrange by Conversation".
// Two messages are in the same conversation when one's References header names
// the other, or both name the same earlier email; or when one is a reply or
// forward ("Re:", "Fwd:") with the same subject as the other, for email apps
// that leave References out.

import Foundation

// One conversation: its messages, newest first. The newest one stands for the
// conversation in the message list; the others are tucked under it.
struct Conversation: Identifiable {
    let messages: [MailMessage]

    var newest: MailMessage { messages[0] }
    var id: MailMessage.ID { newest.id }
}

enum Conversations {
    // Splits messages into conversations. Each conversation's messages are newest
    // first, and the conversations are ordered by their newest message, newest first.
    static func group(_ messages: [MailMessage]) -> [Conversation] {
        // "Union-find": every message starts in a group of its own, and `join`
        // merges two groups. `leader[i]` points towards the message that stands
        // for message i's group; following the pointers ends at that message.
        var leader = Array(messages.indices)
        func groupLeader(_ index: Int) -> Int {
            var current = index
            while leader[current] != current {
                leader[current] = leader[leader[current]]   // shortcut, so later lookups are quicker
                current = leader[current]
            }
            return current
        }
        func join(_ first: Int, _ second: Int) {
            leader[groupLeader(first)] = groupLeader(second)
        }

        // Messages naming the same email (their own Message-ID, or one in their
        // References) belong together. The first message to name an ID "owns" it.
        var ownerOfID: [String: Int] = [:]
        // The first message seen with each subject, for joining replies by subject.
        var ownerOfTopic: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            for id in [message.messageID].compactMap({ $0 }) + message.references {
                if let owner = ownerOfID[id] { join(index, owner) } else { ownerOfID[id] = index }
            }
            let (topic, isReply) = topic(of: message.subject)
            guard !topic.isEmpty else { continue }
            if let owner = ownerOfTopic[topic] {
                // Only a reply or forward joins by subject, so two separate emails that
                // happen to share a subject (like "Your receipt") stay apart.
                if isReply { join(index, owner) }
            } else {
                ownerOfTopic[topic] = index
            }
        }

        // `Dictionary(grouping:by:)` sorts the messages into buckets, one per group.
        let groups = Dictionary(grouping: messages.indices, by: groupLeader).values
        return groups
            .map { indices in Conversation(messages: indices.map { messages[$0] }.sorted { $0.dateReceived > $1.dateReceived }) }
            .sorted { $0.newest.dateReceived > $1.newest.dateReceived }
    }

    // A subject without "Re:", "Fwd:" and the like in front, in lowercase, plus
    // whether it had any: "Re: Fwd: Lunch?" → ("lunch?", true).
    // "(No subject)" counts as no subject at all, so those never join up.
    static func topic(of subject: String) -> (topic: String, isReply: Bool) {
        var topic = subject.lowercased().trimmingCharacters(in: .whitespaces)
        var isReply = false
        // Each pass removes one prefix. `.anchored` means it must be at the start.
        while let prefix = topic.range(of: #"^(re|fw|fwd|aw|sv|wg)\s*(\[\d+\])?\s*:\s*"#, options: [.regularExpression, .anchored]) {
            topic.removeSubrange(prefix)
            isReply = true
        }
        return (topic == "(no subject)" ? "" : topic, isReply)
    }
}
