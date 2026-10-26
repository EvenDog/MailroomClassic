// Keeps one IMAP connection open per account, so clicking around doesn't have
// to connect and log in every time. An IMAP connection can only do one thing at
// once, so jobs wait in line and run one at a time, in the order they arrived.
// If the server is too slow to answer, a job gets one more try on a fresh connection.

import Foundation
import SwiftMail

final class AccountConnection {
    private let account: AccountSettings
    private var server: IMAPServer?
    private var lastUsed = Date.distantPast

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
        let newServer = try await IMAPService.connectAndLogIn(account)
        server = newServer
        lastUsed = Date()
        return newServer
    }
}
