import Foundation

/// One `execute` or `challengeAccount` call (protocol v1 sections 10, 13 and 23).
///
/// `execute` runs rounds. Each round runs entirely under one deadline race (`Deadline.race`: a
/// monotonic timer, the loser abandoned, so a stuck App Attest call cannot stretch it):
/// 1. the app challenge (`app: {platform: "ios", id: <bundle id>}`);
/// 2. `siteId` must be present, and a sealed `appId` must be this app's (R4: the bundle id, or a
///    10-character Team ID, `.`, the bundle id), else `invalid-response`;
/// 3. the proof of work;
/// 4. the binding bytes `B`, with that App ID;
/// 5. the attestation evidence for SHA-256(`B`);
/// 6. the solve;
/// 7. a token is returned; a puzzle is shown on the hosted page (whose URL names the bundle id,
///    which the page matches against the site's app list; the sealed App ID belongs in `B`
///    only), or with `.never` the call fails with `challengeRequired` and sends nothing more.
///
/// The answer's `attestation` status (token and puzzle alike) is passed to the provider after
/// the round's race, outside the deadline, so a token the server issued is never lost to a
/// timeout while the provider waits for its gate. It runs in its own task, so it completes even
/// when the call stops waiting (after `settleBound` seconds).
///
/// The total deadline is a budget: the time the sheet is on screen is not counted. The page's
/// `puzzle-retry` and `puzzle-new` are answered by a fresh round (a new challenge solved
/// natively, never in the page), at most `maxRounds` rounds. Cancelling the calling task ends
/// the call with `cancelled`: the race returns at once and cancels the PoW and network calls, and
/// the presenter closes the sheet.
struct Executor: Sendable, RedactedDescription {
    struct Settings: Sendable, RedactedDescription {
        let siteKey: String
        let widgetOrigin: URL
        let timeout: TimeInterval
        let locale: String
        let theme: Configuration.Theme
        let sdk: SDKIdentity
        let bundleId: String
        let log: Log

        var redactedName: String { "Executor.Settings" }
    }

    var redactedName: String { "Executor" }

    /// Rounds one call may run (each a native solve, most of them after the page asked for a
    /// new puzzle).
    static let maxRounds = 10
    /// `PAGE_RESOLVE_CODES`: the page's codes that ask for a fresh native solve.
    static let resolveCodes: Set<String> = ["puzzle-retry", "puzzle-new"]

    let settings: Settings
    let transport: any Transport
    let provider: any AttestationProvider
    let presenter: any ChallengePresenter

    /// How long a call waits for the provider to take in the server's status.
    static let settleBound: TimeInterval = 2

    private struct Round: Sendable {
        enum Kind: Sendable {
            case token(String)
            case puzzle(ChallengeSheet)
        }

        let kind: Kind
        let evidence: AttestationEvidence
        let status: String?
    }

    func execute(action: String?, cdata: String?, presentation: Presentation)
        async throws(RevokeGPTError) -> String {
        if let action, !Validation.isAction(action) { throw .invalidArgument(field: "action") }
        if let cdata, !Validation.isCdata(cdata) { throw .invalidArgument(field: "cdata") }
        var budget = settings.timeout
        for _ in 0..<Self.maxRounds {
            guard budget > 0 else { throw .timeout }
            let deadline = Deadline(after: budget)
            let round = try await run(deadline) {
                try await self.solveRound(action: action, cdata: cdata, deadline: deadline)
            }
            budget = deadline.remaining
            await settle(round)
            switch round.kind {
            case .token(let token):
                return token
            case .puzzle(let sheet):
                if case .never = presentation { throw .challengeRequired }
                let result = await presenter.present(sheet, presentation: presentation)
                if Task.isCancelled { throw .cancelled }
                switch result {
                case .token(let token):
                    guard Validation.isResponseToken(token) else { throw .invalidResponse }
                    return token
                case .error(let code) where Self.resolveCodes.contains(code):
                    continue
                default:
                    throw Self.error(for: result)
                }
            }
        }
        throw .internal
    }

    /// Account verification (section 17): the hosted page with an `mfa` message. No network
    /// call of the SDK's own, so no deadline: only the sheet's time.
    func challengeAccount(requestToken: String, languageCode: String?, presentation: Presentation)
        async throws(RevokeGPTError) -> String {
        guard Validation.isResponseToken(requestToken) else {
            throw .invalidArgument(field: "requestToken")
        }
        if let languageCode, !Validation.isLanguageCode(languageCode) {
            throw .invalidArgument(field: "languageCode")
        }
        if case .never = presentation { throw .challengeRequired }
        let sheet = ChallengeSheet(
            content: .mfa(requestToken: requestToken, languageCode: languageCode),
            widgetOrigin: settings.widgetOrigin, siteKey: settings.siteKey,
            appId: settings.bundleId, locale: settings.locale, theme: settings.theme)
        let result = await presenter.present(sheet, presentation: presentation)
        if Task.isCancelled { throw .cancelled }
        guard case .token(let token) = result else { throw Self.error(for: result) }
        guard Validation.isResponseToken(token) else { throw .invalidResponse }
        return token
    }

    /// The error for a sheet that ended without a token. A page code that is an API code passes
    /// through (status 0: it came from the page, not an HTTP answer); any other code, the
    /// resolve codes included where they have no meaning, is `internal`.
    static func error(for result: ChallengeResult) -> RevokeGPTError {
        switch result {
        case .cancelled: .cancelled
        case .noWindow: .challengeRequired
        case .unsupported: .challengeUnsupported
        case .busy: .busy
        case .failed: .internal
        case .network: .network
        case .timedOut: .timeout
        case .invalidMessage, .token: .invalidResponse
        case .error(let code):
            RevokeGPTError.apiErrorCodes.contains(code)
                ? .api(code: code, status: 0, requestId: nil, retryAfterSeconds: nil) : .internal
        }
    }

    /// R4: the bundle id itself, or a Team ID of 10 of `A-Z 0-9`, `.`, then the bundle id.
    static func isOwnAppId(_ appId: String, bundleId: String) -> Bool {
        let a = Array(appId.utf8)
        let b = Array(bundleId.utf8)
        if a == b { return true }
        guard a.count == b.count + 11, a[10] == 0x2E, Array(a[11...]) == b else { return false }
        return a[0..<10].allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    }

    // MARK: One round

    /// Passes the server's status to the provider in a task of its own (not cancelled with the
    /// call, so a promotion is never skipped), waiting for it at most `settleBound` seconds.
    private func settle(_ round: Round) async {
        guard round.status != nil else { return }
        let provider = provider
        let log = settings.log
        let work = Task {
            await provider.handle(
                serverAttestation: round.status, answering: round.evidence, log: log)
        }
        _ = try? await Deadline(after: Self.settleBound).race { await work.value }
    }

    private func run<T: Sendable>(
        _ deadline: Deadline, _ operation: @escaping @Sendable () async throws -> T
    ) async throws(RevokeGPTError) -> T {
        do {
            return try await deadline.race(operation)
        } catch {
            throw Self.map(error)
        }
    }

    /// Codes only.
    static func map(_ error: any Error) -> RevokeGPTError {
        switch error {
        case let e as RevokeGPTError: e
        case is DeadlineExceeded: .timeout
        case is CancellationError: .cancelled
        case let e as PowError: e == .deadlineExceeded ? .timeout : .internal
        default: .internal
        }
    }

    private func solveRound(action: String?, cdata: String?, deadline: Deadline) async throws
        -> Round {
        let s = settings
        let request = Wire.ChallengeRequest(
            siteKey: s.siteKey, bundleId: s.bundleId, action: action, cdata: cdata, sdk: s.sdk)
        let sent = try await transport.post(
            path: Wire.Operation.challenge.path, body: try Wire.encode(request), deadline: deadline)
        let challenge: Wire.ChallengeResponse
        let read = Wire.interpret(
            .challenge, status: sent.status, headers: sent.headers, body: sent.body)
        switch read {
        case .challenge(let c): challenge = c
        case .failure(let f): throw f.error
        default: throw RevokeGPTError.invalidResponse
        }
        guard let siteId = challenge.siteId else { throw RevokeGPTError.invalidResponse }
        let appId: String
        if let sealed = challenge.appId {
            guard Self.isOwnAppId(sealed, bundleId: s.bundleId) else {
                throw RevokeGPTError.invalidResponse
            }
            appId = sealed
        } else {
            // Clients tolerate its absence (section 10): bind the bundle id.
            appId = s.bundleId
        }
        let params: Pow.Params
        do {
            params = try Pow.Params(
                algorithm: challenge.pow.algorithm, salt: challenge.pow.salt,
                difficultyBits: challenge.pow.difficultyBits, count: challenge.pow.count)
        } catch {
            throw RevokeGPTError.invalidResponse
        }
        let solutions = try await Pow.solve(
            salt: params.salt, difficultyBits: params.difficultyBits, count: params.count,
            deadline: deadline, log: s.log)
        let binding: Data
        do {
            binding = try Binding.build(
                cid: params.salt, siteId: siteId, action: action ?? "", solutions: solutions,
                platform: .ios, appId: appId)
        } catch {
            throw RevokeGPTError.internal
        }
        let evidence = await provider.evidence(
            clientDataHash: Binding.clientDataHash(binding), log: s.log)
        // An abandoned round (its race lost) stops here rather than sending a solve.
        try Task.checkCancellation()
        let solve = Wire.SolveRequest(
            challenge: challenge.challenge, solutions: solutions, attestation: evidence)
        let answer = try await transport.post(
            path: Wire.Operation.solve.path, body: try Wire.encode(solve), deadline: deadline)
        let outcome = Wire.interpret(
            .solve, status: answer.status, headers: answer.headers, body: answer.body)
        switch outcome {
        case .token(let token, _, let status):
            return Round(kind: .token(token), evidence: evidence, status: status)
        case .puzzle(let puzzle, let status):
            let sheet = ChallengeSheet(
                content: .puzzle(
                    puzzle.puzzle, signalsKey: challenge.signalsKey, cid: challenge.pow.salt),
                widgetOrigin: s.widgetOrigin, siteKey: s.siteKey, appId: s.bundleId,
                locale: s.locale, theme: s.theme)
            return Round(kind: .puzzle(sheet), evidence: evidence, status: status)
        case .failure(let f):
            throw f.error
        case .challenge:
            throw RevokeGPTError.invalidResponse
        }
    }
}
