import Foundation

/// The DeviceCheck fallback (plan R5, protocol v1 section 10): a device token for when App Attest
/// is unsupported (or answers `featureUnsupported`). The token proves a genuine Apple device
/// running the team's app but is not bound to the challenge, so the server scores it below App
/// Attest. Errors and tokens outside the solve schema (1 to 4096 bytes) are
/// `unavailable(internal)`.
struct DeviceCheckProvider: Sendable {
    let service: any DeviceTokenService

    func evidence(log: Log = .off) async -> AttestationEvidence {
        guard service.isSupported else {
            log.event(.attestUnsupported)
            return .unavailable(code: "unsupported")
        }
        do {
            let token = try await service.generateToken()
            guard (1...4096).contains(token.count) else {
                log.event(.attestDeviceCheckFailed)
                return .unavailable(code: "internal")
            }
            log.event(.attestDeviceCheck)
            return .deviceCheck(token: token.base64EncodedString())
        } catch {
            log.event(.attestDeviceCheckFailed)
            return .unavailable(code: "internal")
        }
    }
}
