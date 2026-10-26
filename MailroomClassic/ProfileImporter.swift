// Reads email account settings out of an Apple configuration profile
// (a ".mobileconfig" file, which mail providers like MXroute offer for Apple
// Mail), so the Settings form can be filled in automatically.

import Foundation
import Security

// The account settings found in a profile.
struct ImportedAccount {
    var provider: MailProvider
    var senderName: String
    var emailAddress: String
    var displayName: String
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int
    var password: String?    // most profiles leave this out
}

enum ProfileImporter {
    // Returns every IMAP email account in the profile (usually just one).
    // Throws if the file isn't a profile or has no IMAP accounts in it.
    static func accounts(in fileURL: URL) throws -> [ImportedAccount] {
        let data = try Data(contentsOf: fileURL)
        // Try reading it directly; if that fails, it may be a signed profile, so unwrap it first.
        let unwrapped = unwrapSignedProfile(data)
        guard let profile = propertyList(from: data) ?? unwrapped.flatMap({ propertyList(from: $0) }) else {
            throw MailError(message: "This file isn't a configuration profile Mailroom Classic can read.")
        }

        // A profile holds a list of "payloads": one per thing it configures.
        let payloads = profile["PayloadContent"] as? [[String: Any]] ?? []
        let mailPayloads = payloads.filter { $0["PayloadType"] as? String == "com.apple.mail.managed" }
        guard !mailPayloads.isEmpty else {
            throw MailError(message: "This profile doesn't contain an email account.")
        }

        let accounts = mailPayloads.compactMap { makeAccount(from: $0) }   // compactMap skips POP accounts
        guard !accounts.isEmpty else {
            throw MailError(message: "This profile's email account uses POP, which Mailroom Classic doesn't support. Only IMAP accounts can be imported.")
        }
        return accounts
    }

    // Checks whether a server name can be found on the internet (a DNS lookup).
    // Runs in the background because the lookup can take a moment.
    static func serverExists(_ host: String) async -> Bool {
        await Task.detached {
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, nil, &result)   // the standard C "look up this name" function
            if result != nil { freeaddrinfo(result) }
            return status == 0
        }.value
    }

    // MARK: - Helpers

    // Turns one mail payload into an ImportedAccount. Returns nil for POP accounts.
    private static func makeAccount(from payload: [String: Any]) -> ImportedAccount? {
        guard payload["EmailAccountType"] as? String == "EmailTypeIMAP" else { return nil }
        func text(_ key: String) -> String { (payload[key] as? String) ?? "" }

        let imapHost = text("IncomingMailServerHostName")
        let email = text("EmailAddress")
        let host = imapHost.lowercased()
        let provider: MailProvider = host == "imap.gmail.com" ? .gmail
            : host == "outlook.office365.com" ? .office365
            : .other

        return ImportedAccount(
            provider: provider,
            senderName: text("EmailAccountName"),
            emailAddress: email,
            displayName: text("EmailAccountDescription") == email ? "" : text("EmailAccountDescription"),
            imapHost: imapHost,
            imapPort: payload["IncomingMailServerPortNumber"] as? Int ?? 993,
            smtpHost: text("OutgoingMailServerHostName"),
            smtpPort: payload["OutgoingMailServerPortNumber"] as? Int ?? 465,
            password: payload["IncomingPassword"] as? String
        )
    }

    // Reads a property list (Apple's settings-file format, in XML or binary form).
    private static func propertyList(from data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    // Signed profiles wrap the settings in a digital signature (the "CMS" format).
    // macOS's CMSDecoder unwraps it and hands back the settings inside.
    // We only need what's inside, so we don't check who signed it.
    private static func unwrapSignedProfile(_ data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let status = data.withUnsafeBytes { bytes in
            CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, data.count)
        }
        guard status == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }
}
