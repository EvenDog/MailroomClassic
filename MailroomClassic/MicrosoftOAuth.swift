// "Sign in with Microsoft" for Office 365 accounts, using OAuth 2.0 with PKCE.
// Microsoft no longer accepts plain passwords for IMAP/SMTP, so instead the
// app gets a short-lived access token (used to log in) and a long-lived
// refresh token (kept in the Keychain, used to get new access tokens).

import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

enum MicrosoftOAuth {
    // The sign-in page sends you back to the app at this address. It must match
    // the redirect URI registered for your app in the Azure portal (see README).
    static let redirectURI = "mailroomclassic://oauth"
    private static let callbackScheme = "mailroomclassic"

    // Mailroom Classic's own Azure app registration, used when an account doesn't
    // supply its own client ID. It's not a secret: desktop apps can't keep one,
    // so Microsoft treats this kind of ID as public (Thunderbird publishes theirs too).
    private static let builtInClientID = "210d788e-c727-4d18-a5fe-c05324e342a1"

    // What the app asks permission for: read mail over IMAP, send over SMTP,
    // and "offline_access", which is what makes Microsoft hand out a refresh token.
    private static let scopes = "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send offline_access"

    // "common" lets both work/school and personal Microsoft accounts sign in.
    private static let authorizeEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    private static let tokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

    // Access tokens kept in memory until they expire, so we don't ask Microsoft for every click.
    private static var cachedAccessTokens: [UUID: (token: String, expires: Date)] = [:]

    // Shows Microsoft's sign-in page in a secure popup. Returns the refresh
    // token, which the caller saves to the Keychain.
    static func signIn(account: AccountSettings, using session: WebAuthenticationSession) async throws -> String {
        let clientID = clientIDToUse(for: account)
        let codeVerifier = randomURLSafeString()   // the PKCE secret
        let state = randomURLSafeString()          // checked on return, to make sure the reply is for us

        var components = URLComponents(string: authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "login_hint", value: account.emailAddress),
        ]

        let callbackURL = try await session.authenticate(
            using: components.url!,
            callback: .customScheme(callbackScheme),
            additionalHeaderFields: [:]
        )

        // The callback looks like mailroomclassic://oauth?code=...&state=...
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = value("error") {
            throw MailError(message: value("error_description") ?? error)
        }
        guard value("state") == state, let code = value("code") else {
            throw MailError(message: "Microsoft's reply didn't match the sign-in request. Please try again.")
        }

        let tokens = try await requestTokens([
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier,
            "scope": scopes,
        ])
        guard let refreshToken = tokens.refreshToken else {
            throw MailError(message: "Microsoft didn't return a refresh token.")
        }
        try cache(tokens, for: account.id)
        return refreshToken
    }

    // Returns a valid access token, getting a fresh one with the saved refresh token if needed.
    static func accessToken(for account: AccountSettings) async throws -> String {
        if let cached = cachedAccessTokens[account.id], cached.expires > Date().addingTimeInterval(60) {
            return cached.token
        }
        let tokens = try await requestTokens([
            "client_id": clientIDToUse(for: account),
            "grant_type": "refresh_token",
            "refresh_token": try AccountStorage.secret(for: account.id),
            "scope": scopes,
        ])
        // Microsoft often hands out a new refresh token too; the old one stops working, so save it.
        if let newRefreshToken = tokens.refreshToken {
            try AccountStorage.saveSecret(newRefreshToken, for: account.id)
        }
        return try cache(tokens, for: account.id)
    }

    static func forgetCachedToken(for accountID: UUID) {
        cachedAccessTokens[accountID] = nil
    }

    // MARK: - Helpers

    // The account's own client ID if it has one, otherwise Mailroom's built-in one.
    private static func clientIDToUse(for account: AccountSettings) -> String {
        guard let clientID = account.microsoftClientID, !clientID.isEmpty else {
            return builtInClientID
        }
        return clientID
    }

    // Remembers the access token and when it expires. Returns the token.
    @discardableResult
    private static func cache(_ tokens: TokenResponse, for accountID: UUID) throws -> String {
        guard let accessToken = tokens.accessToken else {
            throw MailError(message: "Microsoft didn't return an access token.")
        }
        let lifetime = TimeInterval(tokens.expiresIn ?? 3600)
        cachedAccessTokens[accountID] = (accessToken, Date().addingTimeInterval(lifetime))
        return accessToken
    }

    // Sends a form to Microsoft's token endpoint and decodes the JSON reply.
    private static func requestTokens(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(form).utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase   // "access_token" in JSON → accessToken in Swift
        let response = try decoder.decode(TokenResponse.self, from: data)
        if let error = response.error {
            throw MailError(message: response.errorDescription ?? error)
        }
        return response
    }

    // Builds "key=value&key=value", escaping every character that isn't plainly safe.
    private static func formEncode(_ form: [String: String]) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: safe) ?? value)"
        }.joined(separator: "&")
    }

    // 32 random bytes as URL-safe text, used for the PKCE secret and the state check.
    private static func randomURLSafeString() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    // PKCE: the scrambled (SHA-256 hashed) version of the secret that's sent to Microsoft first.
    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // Base64 using the URL-safe alphabet and no "=" padding, as OAuth requires.
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// The JSON Microsoft sends back from the token endpoint (either tokens or an error).
private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?
    let errorDescription: String?
}
