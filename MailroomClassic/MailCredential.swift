// How the app proves who you are to a mail server: either a normal password
// (MXroute, Gmail app passwords) or a Microsoft access token (Office 365).
// Both IMAPService and SMTPService ask for one of these before logging in.

import Foundation

enum MailCredential {
    case password(String)
    case accessToken(String)

    // Looks up (or, for Office 365, fetches) the credential for an account.
    static func forAccount(_ account: AccountSettings) async throws -> MailCredential {
        if account.provider == .office365 {
            return .accessToken(try await MicrosoftOAuth.accessToken(for: account))
        }
        return .password(try AccountStorage.secret(for: account.id))
    }
}
