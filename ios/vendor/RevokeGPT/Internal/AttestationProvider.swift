import DeviceCheck
import Foundation

/// Produces the `attestation` of an app solve (protocol v1 section 10) and learns from the
/// server's `attestation` status on the answer (`ok`, `reattest`, or a value it ignores).
/// Each call takes the caller's `Log`, so one provider (one gate per site key and scope) serves
/// every configuration of that key, whatever its logging setting.
protocol AttestationProvider: Sendable {
    func evidence(clientDataHash: Data, log: Log) async -> AttestationEvidence
    /// The server's status on the solve that sent `evidence`.
    func handle(serverAttestation: String?, answering evidence: AttestationEvidence, log: Log) async
    /// Prepares ahead of a call (App Attest: generates the key), so the first call is faster.
    func prewarm(log: Log) async
}

/// `DCAppAttestService`, behind a protocol so the provider is tested with a fake.
protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// `DCDevice` (the DeviceCheck fallback), behind a protocol.
protocol DeviceTokenService: Sendable {
    var isSupported: Bool { get }
    func generateToken() async throws -> Data
}

/// The system App Attest service. It holds no reference: `DCAppAttestService.shared` is read
/// per call, so the type is trivially Sendable.
struct SystemAppAttestService: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

/// The system DeviceCheck service.
struct SystemDeviceCheck: DeviceTokenService {
    var isSupported: Bool { DCDevice.current.isSupported }

    func generateToken() async throws -> Data {
        try await DCDevice.current.generateToken()
    }
}

/// What the provider does with an App Attest error, by `DCError.Code` (protocol v1 section 23.4,
/// `mobile-client.json` `appAttestErrors`).
enum AppAttestErrorAction: Equatable, Sendable {
    /// Send `unavailable` with this code; the key is kept (`serverUnavailable`: attest the same
    /// key again on the next call; never retried inside one call).
    case unavailable(code: String)
    /// `invalidKey`: drop the key and attest a new one, once.
    case dropKeyAndAttestOnce
    /// `featureUnsupported`: the DeviceCheck fallback.
    case fallbackToDeviceCheck

    init(_ error: any Error) {
        guard let e = error as? DCError else {
            self = .unavailable(code: "internal")
            return
        }
        switch e.code {
        case .serverUnavailable: self = .unavailable(code: "server-unavailable")
        case .invalidKey: self = .dropKeyAndAttestOnce
        case .featureUnsupported: self = .fallbackToDeviceCheck
        case .invalidInput, .unknownSystemFailure: self = .unavailable(code: "internal")
        @unknown default: self = .unavailable(code: "internal")
        }
    }

    /// Whether `error` is a DCError case this mapping names (else a debug event is logged).
    static func isRecognized(_ error: any Error) -> Bool {
        guard let e = error as? DCError else { return false }
        switch e.code {
        case .serverUnavailable, .invalidKey, .featureUnsupported, .invalidInput,
             .unknownSystemFailure:
            return true
        @unknown default:
            return false
        }
    }
}
