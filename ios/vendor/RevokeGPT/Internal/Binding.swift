import CryptoKit
import Foundation

/// Why `Binding.build` refused its input.
enum BindingError: Error, Equatable, Sendable {
    /// buildAttestBinding's RangeError: a `cid` other than 16 bytes, a field over 255 bytes, or a
    /// solution above 2^53 - 1. (Negative and fractional solutions cannot be a `UInt64`.)
    case range
    /// buildAttestBinding's TypeError for a non-ASCII `siteId` or `action`. (A Swift `String` is
    /// always well-formed Unicode, so the lone-surrogate refusal has no counterpart.)
    case notASCII
}

/// The attestation binding bytes `B` (protocol v1 section 10, App attestation binding), a native
/// port of `buildAttestBinding` in packages/protocol/src/attest.ts, byte for byte (pinned by
/// packages/protocol/test-vectors/attest-binding.json, BindingTests):
///
///     ASCII "rg-attest-v1" || cid (16) || u8 len || siteId (ASCII) || u8 len || action (ASCII)
///     || SHA-256(solutions as consecutive 8-byte big-endian unsigned integers)
///     || u8 platform (1 android, 2 ios) || u8 len || appId (UTF-8)
///
/// On iOS `appId` is the App ID `<teamId>.<bundleId>`, and the App Attest `clientDataHash` is
/// SHA-256(B). The server rebuilds `B` itself; the client never sends it.
enum Binding {
    enum Platform: UInt8, Sendable {
        case android = 1
        case ios = 2
    }

    private static let domain = Array("rg-attest-v1".utf8)

    static func build(
        cid: Data, siteId: String, action: String, solutions: [UInt64], platform: Platform,
        appId: String
    ) throws(BindingError) -> Data {
        guard cid.count == 16 else { throw .range }
        let site = Array(siteId.utf8)
        let act = Array(action.utf8)
        // ASCII is exactly the UTF-8 bytes below 0x80.
        guard site.allSatisfy({ $0 < 0x80 }), act.allSatisfy({ $0 < 0x80 }) else {
            throw .notASCII
        }
        let app = Array(appId.utf8)
        guard site.count <= 255, act.count <= 255, app.count <= 255 else { throw .range }
        var nonces = SHA256()
        for n in solutions {
            guard n <= Pow.maxNonce else { throw .range }
            var be = n.bigEndian
            withUnsafeBytes(of: &be) { nonces.update(bufferPointer: $0) }
        }

        var out = Data(domain)
        out.append(cid)
        out.append(UInt8(site.count))
        out.append(contentsOf: site)
        out.append(UInt8(act.count))
        out.append(contentsOf: act)
        out.append(contentsOf: nonces.finalize())
        out.append(platform.rawValue)
        out.append(UInt8(app.count))
        out.append(contentsOf: app)
        return out
    }

    /// The App Attest `clientDataHash` for binding bytes `b`: SHA-256(b), 32 bytes.
    static func clientDataHash(_ binding: Data) -> Data {
        Data(SHA256.hash(data: binding))
    }
}
