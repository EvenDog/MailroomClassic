// Settings → Rules: your rules (each with Edit and Remove buttons), Run Rules
// Now, and a form to make a new one or change one:
// "If From / Subject / To or Cc contains ___, move it to [folder]".

import SwiftUI

struct RulesSettingsView: View {
    @Environment(MailStore.self) private var store

    // The rule being edited, or nil when the form makes a new one.
    @State private var editingRule: MailRule?
    // What's chosen in the form.
    @State private var field: MailRule.Field = .sender
    @State private var text = ""
    @State private var destinationFolderID: MailFolder.ID?
    @State private var isRunning = false

    private var trimmedText: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section("Rules") {
                if store.rules.isEmpty {
                    Text("No rules yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.rules) { rule in
                    HStack {
                        Text(description(of: rule))
                        Spacer()
                        Button("Edit") { startEditing(rule) }
                        Button("Remove") {
                            if editingRule?.id == rule.id { clearForm() }
                            store.removeRule(rule)
                        }
                    }
                }
                HStack {
                    Text("Rules run on new mail in the Inbox after each check.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Runs the rules on mail that's already in the Inbox, too.
                    Button(isRunning ? "Running…" : "Run Rules Now") {
                        Task {
                            isRunning = true
                            await store.runRulesNow()
                            isRunning = false
                        }
                    }
                    .disabled(store.rules.isEmpty || isRunning)
                }
            }

            Section(editingRule == nil ? "New Rule" : "Edit Rule") {
                Picker("If", selection: $field) {
                    ForEach(MailRule.Field.allCases, id: \.self) { field in
                        Text("\(field.label) contains").tag(field)
                    }
                }
                TextField("this text", text: $text, prompt: Text("e.g. Golf Genius"))
                // Folders grouped by account. A rule only moves mail within that account.
                Picker("Move it to", selection: $destinationFolderID) {
                    Text("Choose a folder").tag(MailFolder.ID?.none)
                    ForEach(store.accounts) { account in
                        Section(account.displayName) {
                            ForEach((store.foldersByAccount[account.id] ?? []).filter { $0.role != .inbox }) { folder in
                                Text(folder.displayName).tag(MailFolder.ID?.some(folder.id))
                            }
                        }
                    }
                }
                HStack {
                    Button(editingRule == nil ? "Add Rule" : "Save Changes") { saveForm() }
                        .disabled(trimmedText.isEmpty || destinationFolderID == nil)
                    if editingRule != nil {
                        Button("Cancel") { clearForm() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // A fixed height that fits on a laptop screen; the form scrolls if it's taller.
        .frame(width: 540, height: 620)
    }

    // Fills the form with a rule, to change it.
    private func startEditing(_ rule: MailRule) {
        editingRule = rule
        field = rule.field
        text = rule.text
        destinationFolderID = rule.destinationFolderID
    }

    // Adds the form as a new rule, or saves it over the rule being edited.
    private func saveForm() {
        guard let destinationFolderID else { return }
        if var rule = editingRule {
            rule.field = field
            rule.text = trimmedText
            rule.destinationFolderID = destinationFolderID
            store.updateRule(rule)
        } else {
            store.addRule(MailRule(field: field, text: trimmedText, destinationFolderID: destinationFolderID))
        }
        clearForm()
    }

    private func clearForm() {
        editingRule = nil
        text = ""
    }

    // e.g. "From contains “golf” → Golf (Gmail)"
    private func description(of rule: MailRule) -> String {
        let condition = "\(rule.field.label) contains “\(rule.text)”"
        guard let folder = store.allFolders.first(where: { $0.id == rule.destinationFolderID }),
              let account = store.accounts.first(where: { $0.id == folder.accountID }) else {
            return condition + " → (that folder no longer exists)"
        }
        return condition + " → \(folder.displayName) (\(account.displayName))"
    }
}
