// Settings → Accounts: your accounts (with Edit and Remove), and a sheet with the form
// to add a new account or edit an existing one (including its signature). The form changes
// with the account type: Gmail, Office 365 and Proton Mail fill in their own server settings,
// and Office 365 signs in through Microsoft's sign-in page instead of a password. The form
// can also be filled in from a provider's configuration profile (.mobileconfig).
// The other Settings tabs are in SettingsTabs.swift and RulesSettingsView.swift.
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct AccountsSettingsView: View {
    // `@Environment` reads values the app hands down to every view: here, the
    // shared MailStore and Apple's helper for showing secure sign-in pages.
    @Environment(MailStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    // Whether the add/edit account sheet is showing.
    @State private var isShowingAccountForm = false
    // The account being edited, or nil when the form is adding a new one.
    @State private var editingAccount: AccountSettings?

    // What's typed into the account form.
    @State private var provider: MailProvider = .other
    @State private var senderName = ""
    @State private var emailAddress = ""
    @State private var displayName = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var password = ""
    @State private var microsoftClientID = ""
    @State private var signature = ""

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isChoosingProfile = false
    @State private var importMessage: String?      // e.g. "Filled in from profile…"
    @State private var importWarning: String?      // e.g. the server name doesn't exist

    private var formIsComplete: Bool {
        // When editing, an empty password means "keep the current one".
        let passwordIfNeeded = editingAccount == nil ? [password] : []
        let required: [String] = switch provider {
        case .other: [senderName, emailAddress, imapHost] + passwordIfNeeded
        case .gmail: [senderName, emailAddress] + passwordIfNeeded
        case .office365: [senderName, emailAddress]
        case .proton: [senderName, emailAddress] + passwordIfNeeded
        }
        return !required.contains { trimmed($0).isEmpty }
    }

    // Office 365 has to sign in again if the email address or client ID changed.
    private var editNeedsMicrosoftSignIn: Bool {
        guard let editingAccount, editingAccount.provider == .office365 else { return false }
        return editingAccount.emailAddress != trimmed(emailAddress)
            || editingAccount.microsoftClientID != trimmed(microsoftClientID)
    }

    private var primaryButtonTitle: String {
        if editingAccount != nil {
            return editNeedsMicrosoftSignIn ? "Sign In with Microsoft & Save…" : "Save Changes"
        }
        return provider == .office365 ? "Sign In with Microsoft…" : "Test & Add Account"
    }

    var body: some View {
        Form {
            Section("Accounts") {
                if store.accounts.isEmpty {
                    Text("No accounts yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.displayName)
                            Text(verbatim: "\(account.emailAddress) · \(account.provider.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") {
                            startEditing(account)
                            isShowingAccountForm = true
                        }
                        Button("Remove", role: .destructive) {
                            store.removeAccount(account)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Account…") { isShowingAccountForm = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 360)
        // A sheet slides down over the Settings window and stays until Cancel or a
        // successful save. `onDismiss` empties the form so the next one starts fresh.
        .sheet(isPresented: $isShowingAccountForm, onDismiss: clearForm) {
            accountForm
        }
    }

    // The add/edit account form shown in the sheet.
    private var accountForm: some View {
        VStack(spacing: 0) {
            Form {
                Section(editingAccount.map { "Edit “\($0.displayName)”" } ?? "Add an Account") {
                    if editingAccount == nil {
                        HStack {
                            Text("Have a setup file from your email provider?")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Import Profile…") { isChoosingProfile = true }
                        }
                    }
                    if let importMessage {
                        Text(importMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let importWarning {
                        Label(importWarning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }

                    Picker("Account type", selection: $provider) {
                        ForEach(MailProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .disabled(editingAccount != nil)   // to change type, remove the account and add it again
                    TextField("Your name", text: $senderName, prompt: Text("Shown to people you email"))
                    TextField("Email address", text: $emailAddress, prompt: Text(verbatim: "you@example.com"))   // `verbatim` stops it being shown as a link
                    TextField("Account name", text: $displayName, prompt: Text("Optional, e.g. Work"))

                    switch provider {
                    case .other:
                        TextField("Incoming (IMAP) server", text: $imapHost, prompt: Text("e.g. xxx.mxrouting.net"))
                        TextField("Incoming port", value: $imapPort, format: .number.grouping(.never))
                        TextField("Outgoing (SMTP) server", text: $smtpHost, prompt: Text("Leave blank if same as incoming"))
                        TextField("Outgoing port", value: $smtpPort, format: .number.grouping(.never))
                        SecureField("Password", text: $password, prompt: passwordPrompt)
                    case .gmail:
                        SecureField("App password", text: $password, prompt: passwordPrompt)
                        Text("Gmail needs an **app password**, not your normal password. Turn on 2-Step Verification, then create one at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .office365:
                        TextField("Microsoft client ID", text: $microsoftClientID, prompt: Text("Optional — leave blank to use Mailroom's"))
                        Text("Office 365 signs in through Microsoft's own page. If your employer's IT blocks outside apps, they'll need to approve Mailroom Classic first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    case .proton:
                        SecureField("Bridge password", text: $password, prompt: passwordPrompt)
                        Text("Proton Mail works through the **Proton Mail Bridge** app, which must be open on this Mac. Use the username and password Bridge shows under Mailbox details, not your Proton password. Bridge's certificate must also be trusted in Keychain Access; the README explains how.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // A TextEditor (rather than a TextField) so Return starts a new line.
                    LabeledContent("Signature") {
                        TextEditor(text: $signature)
                            .font(.body)
                            .frame(height: 70)
                    }
                    Text("Optional. Added to new emails, replies and forwards from this account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel") { isShowingAccountForm = false }
                    .keyboardShortcut(.cancelAction)   // the Esc key
                    .disabled(isWorking)
                Button(primaryButtonTitle) {
                    // `Task { }` starts async work from a button tap, which can't wait itself.
                    Task {
                        if let editingAccount {
                            await saveChanges(to: editingAccount)
                        } else {
                            await addAccount()
                        }
                    }
                }
                .disabled(!formIsComplete || isWorking)
            }
            .padding()
        }
        // A fixed size that fits on a laptop screen; the form scrolls if it's taller.
        .frame(width: 500, height: 580)
        // The standard "choose a file" window, limited to configuration profiles.
        .fileImporter(isPresented: $isChoosingProfile, allowedContentTypes: [Self.profileType]) { result in
            if case .success(let url) = result {
                Task { await importProfile(from: url) }
            }
        }
    }

    // The password to use. Google shows app passwords in groups of four letters
    // ("abcd efgh ijkl mnop"); the spaces aren't part of it, so Gmail's are removed.
    private var typedPassword: String {
        provider == .gmail ? password.filter { !$0.isWhitespace } : password
    }

    private var passwordPrompt: Text? {
        editingAccount == nil ? nil : Text("Leave blank to keep the current one")
    }

    // The file type for ".mobileconfig" files (falls back to "any data" if macOS doesn't know it).
    private static let profileType = UTType(filenameExtension: "mobileconfig") ?? .data

    // Fills the form from a profile, then warns if its server name can't be found.
    private func importProfile(from url: URL) async {
        errorMessage = nil
        importWarning = nil
        do {
            let accounts = try ProfileImporter.accounts(in: url)
            let imported = accounts[0]
            provider = imported.provider
            senderName = imported.senderName
            emailAddress = imported.emailAddress
            displayName = imported.displayName
            imapHost = imported.imapHost
            imapPort = imported.imapPort
            // Same server for both? Leave Outgoing blank ("same as incoming"), so fixing one fixes both.
            smtpHost = imported.smtpHost.caseInsensitiveCompare(imported.imapHost) == .orderedSame ? "" : imported.smtpHost
            smtpPort = imported.smtpPort
            password = imported.password ?? ""

            var message = "Filled in from \(url.lastPathComponent)."
            if imported.password == nil { message += " Enter your password, then click Test & Add Account." }
            if accounts.count > 1 { message += " (The profile has \(accounts.count) accounts; this is the first.)" }
            importMessage = message

            if imported.provider == .other, !(await ProfileImporter.serverExists(imported.imapHost)) {
                importWarning = "The server “\(imported.imapHost)” from this profile can't be found on the internet, so it's probably wrong. Ask your email provider for the correct server name (for MXroute, it's in your welcome email, like xxx.mxrouting.net)."
            }
        } catch {
            importMessage = nil
            errorMessage = "Couldn't import the profile: \(error.localizedDescription)"
        }
    }

    // Fills the form with an existing account's settings, ready to edit.
    private func startEditing(_ account: AccountSettings) {
        clearForm()
        editingAccount = account
        provider = account.provider
        senderName = account.senderName
        emailAddress = account.emailAddress
        displayName = account.displayName == account.emailAddress ? "" : account.displayName
        imapHost = account.imapHost
        imapPort = account.imapPort
        smtpHost = account.smtpHost.caseInsensitiveCompare(account.imapHost) == .orderedSame ? "" : account.smtpHost
        smtpPort = account.smtpPort
        microsoftClientID = account.microsoftClientID ?? ""
        signature = account.signature ?? ""
    }

    // Tests the edited settings and saves them. On failure, the account stays as it was.
    private func saveChanges(to original: AccountSettings) async {
        isWorking = true
        errorMessage = nil
        var updated = makeAccount()
        updated.id = original.id   // same account, new settings
        do {
            var newSecret: String? = trimmed(password).isEmpty ? nil : typedPassword
            if updated.provider == .office365 {
                newSecret = editNeedsMicrosoftSignIn
                    ? try await MicrosoftOAuth.signIn(account: updated, using: webAuthenticationSession)
                    : nil
            }
            try await store.updateAccount(updated, newSecret: newSecret)
            isShowingAccountForm = false   // closing the sheet also clears the form
        } catch {
            errorMessage = "Couldn't save the changes: \(FriendlyError.message(for: error, server: updated.imapHost))"
        }
        isWorking = false
    }

    // Builds the account from the form, using the known server settings for Gmail, Office 365 and Proton Mail.
    private func makeAccount() -> AccountSettings {
        let email = trimmed(emailAddress)
        let name = trimmed(displayName)
        var account = AccountSettings(
            provider: provider,
            displayName: name.isEmpty ? email : name,
            senderName: trimmed(senderName),
            emailAddress: email,
            imapHost: trimmed(imapHost),
            imapPort: imapPort,
            smtpHost: trimmed(smtpHost).isEmpty ? trimmed(imapHost) : trimmed(smtpHost),
            smtpPort: smtpPort
        )
        // Blank lines at the start or end of a signature are dropped; an empty one means "no signature".
        let signatureText = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        account.signature = signatureText.isEmpty ? nil : signatureText
        switch provider {
        case .other:
            break
        case .gmail:
            (account.imapHost, account.imapPort) = ("imap.gmail.com", 993)
            (account.smtpHost, account.smtpPort) = ("smtp.gmail.com", 465)
        case .office365:
            (account.imapHost, account.imapPort) = ("outlook.office365.com", 993)
            (account.smtpHost, account.smtpPort) = ("smtp.office365.com", 587)
            account.microsoftClientID = trimmed(microsoftClientID)
        case .proton:
            // Proton Mail Bridge's standard settings: a mail server on this Mac (127.0.0.1).
            (account.imapHost, account.imapPort) = ("127.0.0.1", 1143)
            (account.smtpHost, account.smtpPort) = ("127.0.0.1", 1025)
        }
        return account
    }

    // Signs in (Office 365) or uses the typed password, tests the login, and
    // saves the account. On success, closes the sheet; on failure, shows why.
    private func addAccount() async {
        isWorking = true
        errorMessage = nil
        let account = makeAccount()
        do {
            let secret = provider == .office365
                ? try await MicrosoftOAuth.signIn(account: account, using: webAuthenticationSession)
                : typedPassword
            try await store.addAccount(account, secret: secret)
            isShowingAccountForm = false   // closing the sheet also clears the form
        } catch {
            errorMessage = "Couldn't add the account: \(FriendlyError.message(for: error, server: account.imapHost))"
        }
        isWorking = false
    }

    private func clearForm() {
        editingAccount = nil
        errorMessage = nil
        provider = .other
        importMessage = nil
        importWarning = nil
        senderName = ""
        emailAddress = ""
        displayName = ""
        imapHost = ""
        imapPort = 993
        smtpHost = ""
        smtpPort = 465
        password = ""
        microsoftClientID = ""
        signature = ""
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Which app opens email links (mailto:), and making it this one.
enum DefaultEmailApp {
    // True if macOS currently sends email links to this app.
    static var isThisApp: Bool {
        guard let link = URL(string: "mailto:"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: link) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    // Asks macOS to send email links here. macOS shows its own "Do you want to
    // change your default email app?" question first. Returns an error message, or nil if it worked.
    static func makeThisApp() async -> String? {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
            return nil
        } catch {
            return "Couldn't change it: \(error.localizedDescription)"
        }
    }
}
