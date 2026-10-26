// The Settings window (Mailroom Classic → Settings…, or ⌘,): lists your
// accounts and has a form to add a new one. The form changes with the account
// type: Gmail and Office 365 fill in their own server settings, and Office 365
// signs in through Microsoft's sign-in page instead of a password. The form
// can also be filled in from a provider's configuration profile (.mobileconfig).

import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct AccountsSettingsView: View {
    // `@Environment` reads values the app hands down to every view: here, the
    // shared MailStore and Apple's helper for showing secure sign-in pages.
    @Environment(MailStore.self) private var store
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    // What's typed into the "Add an Account" form.
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

    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isChoosingProfile = false
    @State private var importMessage: String?      // e.g. "Filled in from profile…"
    @State private var importWarning: String?      // e.g. the server name doesn't exist

    private var formIsComplete: Bool {
        let required: [String] = switch provider {
        case .other: [senderName, emailAddress, imapHost, password]
        case .gmail: [senderName, emailAddress, password]
        case .office365: [senderName, emailAddress, microsoftClientID]
        }
        return !required.contains { trimmed($0).isEmpty }
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
                        Button("Remove", role: .destructive) {
                            store.removeAccount(account)
                        }
                    }
                }
            }

            Section("Add an Account") {
                HStack {
                    Text("Have a setup file from your email provider?")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Import Profile…") { isChoosingProfile = true }
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
                TextField("Your name", text: $senderName, prompt: Text("Shown to people you email"))
                TextField("Email address", text: $emailAddress, prompt: Text(verbatim: "you@example.com"))   // `verbatim` stops it being shown as a link
                TextField("Account name", text: $displayName, prompt: Text("Optional, e.g. Work"))

                switch provider {
                case .other:
                    TextField("Incoming (IMAP) server", text: $imapHost, prompt: Text("e.g. xxx.mxrouting.net"))
                    TextField("Incoming port", value: $imapPort, format: .number.grouping(.never))
                    TextField("Outgoing (SMTP) server", text: $smtpHost, prompt: Text("Leave blank if same as incoming"))
                    TextField("Outgoing port", value: $smtpPort, format: .number.grouping(.never))
                    SecureField("Password", text: $password)
                case .gmail:
                    SecureField("App password", text: $password)
                    Text("Gmail needs an **app password**, not your normal password. Turn on 2-Step Verification, then create one at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .office365:
                    TextField("Microsoft client ID", text: $microsoftClientID, prompt: Text("From your Azure app registration"))
                    Text("Office 365 signs in through Microsoft's own page. You need a free Azure app registration first; the README explains how. Your employer's IT may need to approve the app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(provider == .office365 ? "Sign In with Microsoft…" : "Test & Add Account") {
                        // `Task { }` starts async work from a button tap, which can't wait itself.
                        Task { await addAccount() }
                    }
                    .disabled(!formIsComplete || isWorking)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        // The standard "choose a file" window, limited to configuration profiles.
        .fileImporter(isPresented: $isChoosingProfile, allowedContentTypes: [Self.profileType]) { result in
            if case .success(let url) = result {
                Task { await importProfile(from: url) }
            }
        }
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

    // Builds the account from the form, using the known server settings for Gmail and Office 365.
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
        }
        return account
    }

    // Signs in (Office 365) or uses the typed password, tests the login, and
    // saves the account. On success, clears the form; on failure, shows why.
    private func addAccount() async {
        isWorking = true
        errorMessage = nil
        let account = makeAccount()
        do {
            let secret = provider == .office365
                ? try await MicrosoftOAuth.signIn(account: account, using: webAuthenticationSession)
                : password
            try await store.addAccount(account, secret: secret)
            clearForm()
        } catch {
            errorMessage = "Couldn't add the account: \(error.localizedDescription)"
        }
        isWorking = false
    }

    private func clearForm() {
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
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
