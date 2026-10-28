// Sends email over SMTP (the standard protocol for outgoing mail) using the
// SwiftMail library. Like IMAPService, it opens a fresh connection per send.

import Foundation
import SwiftMail

enum SMTPService {
    // Connects to the account's outgoing server, logs in, sends, and disconnects.
    static func send(_ email: Email, from account: AccountSettings) async throws {
        let credential = try await MailCredential.forAccount(account)
        // Proton Mail Bridge needs STARTTLS on port 1025 (see IMAPService.connectAndLogIn).
        let security: MailTransportSecurity = account.provider == .proton ? .startTLS : .automatic
        let server = SMTPServer(host: account.smtpHost, port: account.smtpPort, transportSecurity: security)
        try await server.connect()
        do {
            switch credential {
            case .password(let password):
                try await server.login(username: account.emailAddress, password: password)
            case .accessToken(let token):
                try await server.authenticateXOAUTH2(email: account.emailAddress, accessToken: token)
            }
            _ = try await server.sendEmail(email)   // `_ =` means "ignore the returned receipt"
            try? await server.disconnect()
        } catch {
            try? await server.disconnect()
            throw error
        }
    }
}
