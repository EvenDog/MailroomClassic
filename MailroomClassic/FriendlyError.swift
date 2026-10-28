// Turns technical errors (like "NIOConnectionError error 1") into messages a
// person can act on, like "Couldn't find the server … Check the server name."

import Foundation
import Security
import SwiftMail

enum FriendlyError {
    // Returns a readable explanation of `error`. `server` is the host name
    // involved, if known, so the message can say which server had the problem.
    static func message(for error: Error, server: String? = nil) -> String {
        let place = server.map { "“\($0)”" } ?? "the mail server"              // for the middle of a sentence
        let placeAtStart = server.map { "“\($0)”" } ?? "The mail server"      // for the start of one

        // Network-level errors come from SwiftNIO, the networking library under
        // SwiftMail. Our app doesn't import NIO directly, so we recognize them by type name.
        let typeName = String(reflecting: type(of: error))
        // A server on this Mac is Proton Mail Bridge, which has its own usual problems.
        let isOnThisMac = server == "127.0.0.1" || server == "localhost"
        if isOnThisMac && typeName.contains("NIOConnectionError") {
            return "Couldn't connect to Proton Mail Bridge. Make sure Bridge is open and signed in."
        }
        // `case .tlsFailed?` matches an SMTPError of that kind, whatever text it carries.
        var isCertificateProblem = typeName.contains("NIOSSL") || typeName.contains("BoringSSL")
        if case .tlsFailed? = error as? SMTPError { isCertificateProblem = true }
        if isOnThisMac && isCertificateProblem {
            return "Proton Mail Bridge's security certificate isn't trusted on this Mac yet. Trust it in Keychain Access (see the README)."
        }
        if typeName.contains("NIOConnectionError") {
            return "Couldn't connect to \(place). Check the server name and port, and that you're online."
        }
        if typeName.contains("ChannelError") {
            return "Lost the connection to \(place), or it didn't answer. Try Send/Receive again."
        }
        if typeName.contains("NIOSSL") || typeName.contains("BoringSSL") {
            return "Couldn't make a secure connection to \(place). Its security certificate may not match the server name."
        }

        if let imapError = error as? IMAPError {
            switch imapError {
            case .loginFailed(let serverReply), .authFailed(let serverReply):
                // Gmail says this when it's given your normal Google password instead of an app password.
                if serverReply.localizedCaseInsensitiveContains("application-specific password") {
                    return "Gmail needs an app password here, not your normal Google password. Create one at myaccount.google.com/apppasswords and paste it in."
                }
                // Otherwise include the server's own words: they often say exactly what's wrong.
                // SwiftMail wraps the reply as `no(…)` or `bad(…)`; keep just what's inside.
                let reply = serverReply
                    .replacingOccurrences(of: #"^(no|bad)\((.*)\)$"#, with: "$2", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(placeAtStart) rejected the email address or password." + (reply.isEmpty ? "" : " The server said: “\(reply)”")
            case .timeout:
                return "\(placeAtStart) took too long to answer."
            default:
                break
            }
        }
        if let smtpError = error as? SMTPError {
            switch smtpError {
            case .authenticationFailed:
                return "The outgoing server \(place) rejected the email address or password."
            case .tlsFailed:
                return "Couldn't make a secure connection to the outgoing server \(place)."
            default:
                break
            }
        }
        if let keychainError = error as? KeychainError, keychainError.status == errSecItemNotFound {
            return "This account's password is missing from the Keychain. Edit the account in Settings and enter it again."
        }
        return error.localizedDescription
    }
}
