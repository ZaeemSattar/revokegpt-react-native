/// The SDK name and version sent in the `sdk` field (plan R10). One release train for the four
/// mobile SDKs (R7): VersionTests checks this against the podspec and CHANGELOG.md.
enum SDKVersion {
    static let name = "revokegpt-ios"
    static let version = "0.1.1"
}

/// The `sdk` field of a challenge request: this SDK, or a wrapper over it (Flutter, React
/// Native) that names itself through the `@_spi(Wrapper)` API.
public struct SDKIdentity: Sendable, Equatable, Encodable {
    let name: String
    let version: String

    /// The native iOS SDK.
    static let native = SDKIdentity(trusted: SDKVersion.name, version: SDKVersion.version)

    /// The plugins that may name themselves in the `sdk` field (protocol v1 section 23.5; the same
    /// closed set as Android's `RevokeGPTOptions.Wrapper`). The field is telemetry the server never
    /// trusts, so the set only keeps it honest.
    static let wrapperNames: Set<String> = ["revokegpt-flutter", "revokegpt-react-native"]

    /// A wrapper's name, one of `wrapperNames`, and its version, checked against the server's
    /// charset (`SDK_VERSION`: 1 to 40 of `0-9 A-Z a-z . + -`).
    @_spi(Wrapper) public init(name: String, version: String) throws(RevokeGPTError) {
        let v = Array(version.utf8)
        guard Self.wrapperNames.contains(name) else { throw .invalidArgument(field: "sdk.name") }
        guard (1...40).contains(v.count), v.allSatisfy({
            Validation.isAlnum($0) || [0x2E, 0x2B, 0x2D].contains($0)
        }) else { throw .invalidArgument(field: "sdk.version") }
        self.name = name
        self.version = version
    }

    /// The SDK's own constants (VersionTests and WireTests check them against the charsets).
    private init(trusted name: String, version: String) {
        self.name = name
        self.version = version
    }
}
