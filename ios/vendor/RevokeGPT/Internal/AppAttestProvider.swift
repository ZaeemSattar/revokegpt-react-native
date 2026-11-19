import Foundation

/// App Attest evidence for app solves (protocol v1 section 10, R§2, plan Review Focus 3).
///
/// Order of checks:
/// 1. the Simulator: `unavailable(simulator)`;
/// 2. an app extension (`.appex`): `unavailable(unsupported)`. Apple supports only a few extension
///    kinds "even if isSupported returns true", and DeviceCheck is not offered there either;
/// 3. App Attest unsupported: the DeviceCheck token if DeviceCheck is supported, else
///    `unavailable(unsupported)`;
/// 4. an attested key: an assertion;
/// 5. a pending key (attested, no `ok` yet): attested again;
/// 6. no key: a new key, stored as pending, then attested. It is promoted to attested only
///    when the server answers `ok` to that attestation (`handle(serverAttestation:answering:)`).
///
/// Errors follow `mobile-client.json` `appAttestErrors` (`AppAttestErrorAction`), and nothing is
/// retried in a loop: only `serverUnavailable` keeps the key (for the next call); every other
/// error discards it (`invalidKey` then attests one new key at once). A key store that cannot be
/// read gives `unavailable(internal)`, never an assertion.
///
/// All App Attest work runs through one actor and a FIFO gate, so service calls never overlap,
/// even across the actor's suspension points: two assertions never race the key's counter. A call
/// waiting for the gate gives up (`unavailable(internal)`) when its task is cancelled.
///
/// App Clips are not supported: a clip has its own bundle id (the site's app list must name it),
/// and sharing a key with the full app would need an app-group Keychain access group.
actor AppAttestProvider: AttestationProvider, RedactedDescription {
    struct Environment: Sendable {
        var isSimulator: Bool
        var isAppExtension: Bool

        static var current: Environment {
            #if targetEnvironment(simulator)
                let simulator = true
            #else
                let simulator = false
            #endif
            return Environment(
                isSimulator: simulator,
                isAppExtension: isAppExtension(bundlePath: Bundle.main.bundlePath))
        }

        static func isAppExtension(bundlePath: String) -> Bool { bundlePath.hasSuffix(".appex") }
    }

    private let service: any AppAttestService
    private let deviceCheck: DeviceCheckProvider
    private let keyStore: any KeyStore
    private let environment: Environment
    /// The log of the call in progress (set by each entry point; the gate serialises them).
    private var log: Log
    private var gateHeld = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiter: UInt64 = 0

    init(
        service: any AppAttestService, deviceCheck: any DeviceTokenService,
        keyStore: any KeyStore, environment: Environment, log: Log = .off
    ) {
        self.service = service
        self.deviceCheck = DeviceCheckProvider(service: deviceCheck)
        self.log = log
        self.keyStore = keyStore
        self.environment = environment
    }

    /// It sees key ids: prints as its type name only.
    nonisolated var redactedName: String { "AppAttestProvider" }

    /// The system services and the Keychain, for one site key and optional key scope.
    static func system(siteKey: String, keyScope: String?) -> AppAttestProvider {
        AppAttestProvider(
            service: SystemAppAttestService(), deviceCheck: SystemDeviceCheck(),
            keyStore: KeychainKeyStore(siteKey: siteKey, keyScope: keyScope),
            environment: .current)
    }

    /// Tests and the default arguments: calls without a log.
    func evidence(clientDataHash: Data) async -> AttestationEvidence {
        await evidence(clientDataHash: clientDataHash, log: .off)
    }

    func handle(serverAttestation status: String?, answering evidence: AttestationEvidence) async {
        await handle(serverAttestation: status, answering: evidence, log: .off)
    }

    func prewarm() async { await prewarm(log: .off) }

    func evidence(clientDataHash: Data, log: Log) async -> AttestationEvidence {
        if environment.isSimulator {
            log.event(.attestSimulator)
            return .unavailable(code: "simulator")
        }
        if environment.isAppExtension {
            log.event(.attestAppExtension)
            return .unavailable(code: "unsupported")
        }
        guard service.isSupported else { return await deviceCheck.evidence(log: log) }
        guard await acquire() else { return .unavailable(code: "internal") }
        defer { release() }
        self.log = log
        return await appAttest(clientDataHash)
    }

    /// Learns from the server's `attestation` status on the solve that sent `evidence`:
    /// - `ok` to an attestation promotes that key, only while it is still the pending key (a key
    ///   replaced meanwhile, say after `invalidKey` in a concurrent call, is not promoted);
    /// - `reattest` deletes the key `evidence` used, from whichever slot still holds it;
    /// - no status, or one this SDK does not know, is ignored (section 10).
    func handle(
        serverAttestation status: String?, answering evidence: AttestationEvidence, log: Log
    ) async {
        let keyId: String
        switch evidence {
        case .appAttestAttestation(let k, _), .appAttestAssertion(let k, _): keyId = k
        default: return
        }
        guard status == "ok" || status == "reattest" else { return }
        guard await acquire() else { return }
        defer { release() }
        self.log = log
        let keys: StoredKeys
        do {
            keys = try await keyStore.load()
        } catch {
            log.event(.attestKeyStoreError)
            return
        }
        do {
            if status == "ok" {
                guard case .appAttestAttestation = evidence, keys.pending == keyId else { return }
                try await keyStore.save(keyId: keyId, in: .attested)
                try await keyStore.delete(.pending)
                log.event(.attestKeyPromoted)
            } else {
                for slot in KeySlot.allCases where keys[slot] == keyId {
                    try await keyStore.delete(slot)
                }
                log.event(.attestKeyDropped)
            }
        } catch {
            log.event(.attestKeyStoreError)
        }
    }

    /// Generates a key ahead of time when there is none, stored as pending, so the first call
    /// only attests it. Nothing happens where App Attest cannot be used.
    func prewarm(log: Log) async {
        guard !environment.isSimulator, !environment.isAppExtension, service.isSupported else {
            return
        }
        guard await acquire() else { return }
        defer { release() }
        self.log = log
        guard let keys = try? await keyStore.load(), keys.attested == nil, keys.pending == nil,
              let keyId = try? await service.generateKey(), Validation.isAppAttestKeyId(keyId)
        else { return }
        do {
            try await keyStore.save(keyId: keyId, in: .pending)
        } catch {
            log.event(.attestKeyStoreError)
        }
    }

    // MARK: App Attest

    private func appAttest(_ hash: Data) async -> AttestationEvidence {
        let keys: StoredKeys
        do {
            keys = try await keyStore.load()
        } catch {
            log.event(.attestKeyStoreError)
            return .unavailable(code: "internal")
        }
        if let keyId = keys.attested {
            do {
                return try await assertion(keyId, hash)
            } catch {
                return await recover(from: error, slot: .attested, hash: hash, isRetry: false)
            }
        }
        if let keyId = keys.pending {
            do {
                return try await attestation(keyId, hash)
            } catch {
                return await recover(from: error, slot: .pending, hash: hash, isRetry: false)
            }
        }
        return await attestNewKey(hash, isRetry: false)
    }

    /// Acts on an error of the key in `slot` (protocol v1 section 23.4, `appAttestErrors`). The key
    /// is kept only on `serverUnavailable`, to attest it again on the next call. Every other error
    /// discards it (Apple: "discard the key id and create a new key"): `invalidKey` attests one
    /// new key at once (unless this already is that one); `featureUnsupported` sends the
    /// DeviceCheck token; anything else sends `unavailable`, and the next call makes a new key.
    /// Nothing loops.
    private func recover(from error: any Error, slot: KeySlot, hash: Data, isRetry: Bool) async
        -> AttestationEvidence {
        let action = errorAction(error)
        if case .unavailable("server-unavailable") = action {
            return .unavailable(code: "server-unavailable")
        }
        do {
            try await keyStore.delete(slot)
            log.event(.attestKeyDropped)
        } catch {
            log.event(.attestKeyStoreError)
            return .unavailable(code: "internal")
        }
        switch action {
        case .dropKeyAndAttestOnce:
            if isRetry { return .unavailable(code: "internal") }
            return await attestNewKey(hash, isRetry: true)
        case .fallbackToDeviceCheck:
            return await deviceCheck.evidence(log: log)
        case .unavailable(let code):
            return .unavailable(code: code)
        }
    }

    /// Generates a key, stores it as pending, and attests it. `isRetry`: this is already the one
    /// new key `invalidKey` allows.
    private func attestNewKey(_ hash: Data, isRetry: Bool) async -> AttestationEvidence {
        let keyId: String
        do {
            keyId = try await service.generateKey()
        } catch {
            switch errorAction(error) {
            case .fallbackToDeviceCheck: return await deviceCheck.evidence(log: log)
            case .unavailable(let code): return .unavailable(code: code)
            case .dropKeyAndAttestOnce: return .unavailable(code: "internal")
            }
        }
        guard Validation.isAppAttestKeyId(keyId) else {
            log.event(.attestFailed)
            return .unavailable(code: "internal")
        }
        do {
            try await keyStore.save(keyId: keyId, in: .pending)
        } catch {
            // A key that cannot be kept could never be promoted: do not attest it.
            log.event(.attestKeyStoreError)
            return .unavailable(code: "internal")
        }
        do {
            return try await attestation(keyId, hash)
        } catch {
            return await recover(from: error, slot: .pending, hash: hash, isRetry: isRetry)
        }
    }

    /// Evidence outside the solve schema (empty or oversize): handled like any other error.
    private struct EvidenceShapeError: Error {}

    private func attestation(_ keyId: String, _ hash: Data) async throws -> AttestationEvidence {
        let object = try await service.attestKey(keyId, clientDataHash: hash)
        guard (1...8192).contains(object.count) else { throw EvidenceShapeError() }
        log.event(.attestAttestation)
        return .appAttestAttestation(keyId: keyId, object: object.base64EncodedString())
    }

    private func assertion(_ keyId: String, _ hash: Data) async throws -> AttestationEvidence {
        let assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
        guard (1...2048).contains(assertion.count) else { throw EvidenceShapeError() }
        log.event(.attestAssertion)
        return .appAttestAssertion(keyId: keyId, assertion: assertion.base64EncodedString())
    }

    private func errorAction(_ error: any Error) -> AppAttestErrorAction {
        let action = AppAttestErrorAction(error)
        if case .unavailable("server-unavailable") = action {
            log.event(.attestServerUnavailable)
        } else if error is EvidenceShapeError {
            log.event(.attestFailed)
        } else if !AppAttestErrorAction.isRecognized(error) {
            log.event(.attestErrorUnrecognized)
        }
        return action
    }

    // MARK: Gate

    /// Holds the gate, waiting in FIFO order; false when the task was cancelled while waiting.
    private func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if !gateHeld {
            gateHeld = true
            return true
        }
        let id = nextWaiter
        nextWaiter += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                // Runs on the actor before suspending, so a cancel handled below finds it.
                if Task.isCancelled {
                    c.resume(returning: false)
                } else {
                    waiters.append((id, c))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(returning: false)
    }

    /// Passes the gate to the next waiter, or frees it.
    private func release() {
        if waiters.isEmpty {
            gateHeld = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
