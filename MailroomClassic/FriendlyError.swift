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
            case .loginFailed, .authFailed:
                return "\(placeAtStart) rejected the email address or password."
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
