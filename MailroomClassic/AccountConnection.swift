// Keeps one IMAP connection open per account, so clicking around doesn't have
// to connect and log in every time. An IMAP connection can only do one thing at
// once, so jobs wait in line and run one at a time, in the order they arrived.
// If the server is too slow to answer, a job gets one more try on a fresh connection.
// If logging in keeps failing, LoginBackoff (below) makes it wait longer between tries.

import Foundation
import SwiftMail

final class AccountConnection {
    private let account: AccountSettings
    private var server: IMAPServer? {
        // A new (or no) connection has no folder open yet.
        didSet { selectedFolderPath = nil }
    }
    private var lastUsed = Date.distantPast
    // The folder open on this connection, if opened with `select` (see below).
    private var selectedFolderPath: String?

    // The most recently queued job. Each new job waits for this one to finish first.
    private var lastJob: Task<Void, Never>?

    // After this long without use, check the connection is still alive before using it.
    // (Servers quietly drop connections that sit idle.)
    private let idleCheckInterval: TimeInterval = 60

    init(account: AccountSettings) {
        self.account = account
    }

    // Runs `job` on this account's connection once every job ahead of it is done.
    // Returns whatever `job` returns, or throws its error. Pass `retryOnTimeout: false`
    // for jobs that mustn't run twice (like saving a copy of a message).
    func run<Result: Sendable>(retryOnTimeout: Bool = true,
                               _ job: @escaping (IMAPServer) async throws -> Result) async throws -> Result {
        let jobAhead = lastJob
        let thisJob = Task {
            await jobAhead?.value   // wait our turn
            do {
                return try await self.perform(job)
            } catch IMAPError.timeout where retryOnTimeout {
                // SwiftMail gives some requests (like logging in) only 5 seconds, and Gmail
                // is sometimes slower than that. `perform` has already thrown the stuck
                // connection away, so try once more on a fresh one before giving up.
                return try await self.perform(job)
            }
        }
        // The next job waits on this one, whether it succeeds or fails.
        lastJob = Task { _ = await thisJob.result }
        return try await thisJob.value
    }

    // Opens a folder on the server unless it's already the open one here, which
    // saves a request when you read several messages in the same folder.
    // Returns whether it really opened it (false means it was skipped).
    // Only call this from inside a job, so jobs don't change it at the same time.
    @discardableResult
    func select(_ folderPath: String, on server: IMAPServer) async throws -> Bool {
        if folderPath == selectedFolderPath { return false }
        try await server.selectMailbox(folderPath)
        selectedFolderPath = folderPath
        return true
    }

    // Forgets which folder is open, so the next `select` really opens it.
    func forgetSelectedFolder() {
        selectedFolderPath = nil
    }

    // Logs out and forgets the connection (e.g. when the account is removed).
    func close() async {
        guard let server else { return }
        self.server = nil
        try? await server.logout()
    }

    private func perform<Result>(_ job: (IMAPServer) async throws -> Result) async throws -> Result {
        let server = try await readyServer()
        do {
            let result = try await job(server)
            lastUsed = Date()
            return result
        } catch {
            // After any failure, start with a fresh connection next time,
            // in case this one was left in a confused state.
            self.server = nil
            try? await server.disconnect()
            throw error
        }
    }

    // Returns the open connection, checking it still works if it's been idle,
    // or opens a new one.
    private func readyServer() async throws -> IMAPServer {
        if let server {
            if Date().timeIntervalSince(lastUsed) < idleCheckInterval {
                return server
            }
            // NOOP is IMAP's "are you still there?" command.
            if (try? await server.noop()) != nil {
                lastUsed = Date()
                return server
            }
            self.server = nil
            try? await server.disconnect()
        }
        try LoginBackoff.checkAllowed(for: account)   // throws while waiting after failed logins
        do {
            let newServer = try await IMAPService.connectAndLogIn(account)
            LoginBackoff.recordSuccess(for: account)
            server = newServer
            lastUsed = Date()
            return newServer
        } catch {
            if !(error is CancellationError) { LoginBackoff.recordFailure(for: account) }
            throw error
        }
    }
}

// Waits longer and longer between login attempts after they fail, instead of
// trying again every few seconds. A struggling server (like Gmail slowing down a
// busy account) gets a rest, and a wrong password doesn't get an IP address blocked.
// Shared by all of an account's connections.
enum LoginBackoff {
    // For each account: how many logins in a row have failed, and when the last one did.
    private static var failures: [UUID: (count: Int, lastFailure: Date)] = [:]

    // How long to wait after this many failures in a row. The first failure is
    // retried straight away, so one hiccup costs nothing.
    private static func waitTime(afterFailures count: Int) -> TimeInterval {
        switch count {
        case ..<2: 0
        case 2: 60          // 1 minute
        case 3: 5 * 60      // 5 minutes
        default: 15 * 60    // 15 minutes
        }
    }

    // Throws a readable error if it's too soon to try logging in to this account again.
    static func checkAllowed(for account: AccountSettings) throws {
        guard let record = failures[account.id] else { return }
        let retryAt = record.lastFailure.addingTimeInterval(waitTime(afterFailures: record.count))
        guard Date() < retryAt else { return }
        throw MailError(message: "Couldn't log in to \(account.imapHost) the last \(record.count) times, so the app is waiting before trying again (at \(retryAt.formatted(date: .omitted, time: .shortened))).")
    }

    static func recordFailure(for account: AccountSettings) {
        failures[account.id] = ((failures[account.id]?.count ?? 0) + 1, Date())
    }

    static func recordSuccess(for account: AccountSettings) {
        failures[account.id] = nil
    }
}
