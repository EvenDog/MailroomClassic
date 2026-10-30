// Color categories, like classic Outlook's: six colored tags (Red, Orange,
// Yellow, Green, Blue, Purple) that can be put on any message, several at
// once, separately from folders. Each is saved on the server as an IMAP
// "keyword" (a hidden tag a server can keep on a message, next to read and
// flagged), e.g. "$CategoryRed", so categories survive reinstalls and show on
// other Macs running Mailroom Classic. (Gmail's website and the iPhone's Mail
// app don't show keywords.) The names you give them ("Urgent", "Work"…) are kept
// in this Mac's settings, so renaming one never changes anything on the server.

import AppKit
import SwiftMail
import SwiftUI

// `nonisolated` and `Sendable`: categories travel with read/flag status, which
// the database works with on its own background thread.
nonisolated enum MailCategory: String, CaseIterable, Codable, Sendable, Comparable {
    case red, orange, yellow, green, blue, purple

    // Its keyword on the server, e.g. "$CategoryRed". (Keywords starting with "$"
    // are, by custom, ones set by mail apps rather than typed by people.)
    var keyword: String {
        "$Category" + rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        }
    }

    // The setting holding this category's name (Settings → Categories).
    var nameKey: String {
        "categoryName." + rawValue
    }

    // Its name: yours if you've renamed it, otherwise e.g. "Red Category" (Outlook's default).
    var name: String {
        let saved = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? defaultName : saved
    }

    var defaultName: String {
        rawValue.capitalized + " Category"
    }

    // Sorted in the order listed above (red first), wherever several are shown.
    static func < (first: MailCategory, second: MailCategory) -> Bool {
        allCases.firstIndex(of: first)! < allCases.firstIndex(of: second)!
    }

    // The categories among a message's flags from the server. Keywords are
    // compared ignoring capitals, because servers may change their case.
    static func from(_ flags: [Flag]) -> Set<MailCategory> {
        var found: Set<MailCategory> = []
        for case .custom(let keyword) in flags {   // only the custom (keyword) flags
            if let category = allCases.first(where: { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }) {
                found.insert(category)
            }
        }
        return found
    }

    // How categories are saved in the local database: e.g. "blue,red". "" means none.
    static func text(for categories: Set<MailCategory>) -> String {
        categories.sorted().map(\.rawValue).joined(separator: ",")
    }

    static func categories(from text: String) -> Set<MailCategory> {
        Set(text.split(separator: ",").compactMap { MailCategory(rawValue: String($0)) })
    }

    // A small filled circle in this color, for menus. Menus on the Mac draw
    // SF Symbols in plain black or white, so this picture is drawn by hand
    // (`isTemplate = false` tells macOS to keep its color).
    var menuDot: Image {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

// A message's categories as a row of small colored dots (in the message list).
struct CategoryDots: View {
    let categories: Set<MailCategory>

    var body: some View {
        HStack(spacing: 3) {
            ForEach(categories.sorted(), id: \.self) { category in
                Circle()
                    .fill(category.color)
                    .frame(width: 8, height: 8)
                    .help(category.name)
            }
        }
        .accessibilityLabel(categories.sorted().map(\.name).joined(separator: ", "))
    }
}

// The Categorize menu's items, shared by the toolbar and the right-click menu:
// each category with a checkmark if every chosen message has it (choosing it
// adds it to all of them, or takes it off if they all have it), then Clear All.
struct CategorizeMenuItems: View {
    let messages: [MailMessage]
    let perform: (MessageAction) -> Void

    var body: some View {
        ForEach(MailCategory.allCases, id: \.self) { category in
            let allHaveIt = !messages.isEmpty && messages.allSatisfy { $0.categories.contains(category) }
            // A Toggle in a menu shows as an item with a checkmark when it's on.
            Toggle(isOn: Binding(get: { allHaveIt }, set: { perform(.setCategory(category, isOn: $0)) })) {
                Label { Text(category.name) } icon: { category.menuDot }
            }
        }
        Divider()
        Button("Clear All Categories") { perform(.clearCategories) }
            .disabled(messages.allSatisfy { $0.categories.isEmpty })
    }
}
