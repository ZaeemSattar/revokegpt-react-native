import CryptoKit
import Foundation
import Security

/// The App Attest key ids this install holds for one site key (and key scope). Prints as its
/// type name only: a key id never reaches a log or a description (section 23.5).
struct StoredKeys: Equatable, Sendable, RedactedDescription {
    /// A key the server accepted (`attestation: "ok"`): used for assertions.
    var attested: String?
    /// A key generated and attested but not yet accepted: attested again on the next call
    /// (Apple: after `serverUnavailable`, "try again later with the same key"). Kept in the
    /// Keychain too, so a crash between the attestation and the answer does not lose it.
    var pending: String?

    init(attested: String? = nil, pending: String? = nil) {
        self.attested = attested
        self.pending = pending
    }

    subscript(slot: KeySlot) -> String? {
        switch slot {
        case .attested: attested
        case .pending: pending
        }
    }

    var redactedName: String { "StoredKeys" }
}

enum KeySlot: String, Sendable, CaseIterable {
    case attested
    case pending
}

enum KeyStoreError: Error, Equatable, Sendable {
    /// The Keychain could not be read or written (locked before first unlock, a missing
    /// entitlement, any other status). The provider then sends `unavailable(internal)`, never an
    /// assertion for a key it could not read.
    case unavailable
}

/// Where the provider keeps its key ids. Async so that a test store can be an actor.
protocol KeyStore: Sendable {
    func load() async throws(KeyStoreError) -> StoredKeys
    func save(keyId: String, in slot: KeySlot) async throws(KeyStoreError)
    func delete(_ slot: KeySlot) async throws(KeyStoreError)
}

/// One Keychain generic-password item.
struct KeychainItem: Hashable, Sendable {
    let service: String
    let account: String
}

/// The four Security calls the key store makes, so tests can check them without a Keychain.
protocol SecItemAPI: Sendable {
    func read(_ item: KeychainItem) async -> (OSStatus, Data?)
    func add(_ item: KeychainItem, data: Data) async -> OSStatus
    func update(_ item: KeychainItem, data: Data) async -> OSStatus
    func delete(_ item: KeychainItem) async -> OSStatus
}

/// The App Attest key ids in the Keychain (plan R9): generic-password items,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never synchronised, so a backup restored
/// on another device carries no key id (the key itself never leaves the Secure Enclave). Nothing
/// else is stored: no UserDefaults, no files.
///
/// Items: service `com.revokegpt.appattest.<SHA-256 hex of the site key>` (one key per site key),
/// account `install.<slot>`, or `scope.<tag>.<slot>` when the app scopes keys to its own user
/// (Apple: one key per user account per device). The tag is HMAC-SHA-256 of the scope under a key
/// derived from the site key, so a tag says nothing across sites; it is still recoverable by
/// brute force from a guessable scope (an email, a small number), so apps should pass an opaque
/// id. Only hashes are stored, never the site key or the scope, and a changed scope reads other
/// items, so it starts a fresh key.
struct KeychainKeyStore: KeyStore, RedactedDescription {
    private let service: String
    private let scopeTag: String
    private let api: any SecItemAPI

    init(siteKey: String, keyScope: String?, api: any SecItemAPI = SystemSecItem()) {
        service = "com.revokegpt.appattest." + Self.hex(siteKey)
        scopeTag = keyScope.map { "scope." + Self.scopeTag($0, siteKey: siteKey) } ?? "install"
        self.api = api
    }

    func item(_ slot: KeySlot) -> KeychainItem {
        KeychainItem(service: service, account: scopeTag + "." + slot.rawValue)
    }

    func load() async throws(KeyStoreError) -> StoredKeys {
        StoredKeys(attested: try await read(.attested), pending: try await read(.pending))
    }

    func save(keyId: String, in slot: KeySlot) async throws(KeyStoreError) {
        let data = Data(keyId.utf8)
        var status = await api.add(item(slot), data: data)
        if status == errSecDuplicateItem { status = await api.update(item(slot), data: data) }
        guard status == errSecSuccess else { throw .unavailable }
    }

    func delete(_ slot: KeySlot) async throws(KeyStoreError) {
        let status = await api.delete(item(slot))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .unavailable }
    }

    /// The key id in `slot`, or nil. A stored value that is not a key id is deleted and read as
    /// absent, so it is never sent as one.
    private func read(_ slot: KeySlot) async throws(KeyStoreError) -> String? {
        let (status, data) = await api.read(item(slot))
        switch status {
        case errSecSuccess:
            if let data, let keyId = String(data: data, encoding: .utf8),
               Validation.isAppAttestKeyId(keyId) {
                return keyId
            }
            try await delete(slot)
            return nil
        case errSecItemNotFound:
            return nil
        default:
            throw .unavailable
        }
    }

    var redactedName: String { "KeychainKeyStore" }

    /// HMAC-SHA-256(key: SHA-256("rg-keyscope-v1:" + siteKey), scope), lowercase hex.
    static func scopeTag(_ scope: String, siteKey: String) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(("rg-keyscope-v1:" + siteKey).utf8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(scope.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Security framework.
struct SystemSecItem: SecItemAPI {
    /// The query naming one item: never synchronised (iCloud Keychain never sees it).
    static func query(_ item: KeychainItem) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// A new item: readable after the first unlock, on this device only.
    static func addAttributes(_ item: KeychainItem, data: Data) -> [String: Any] {
        var q = query(item)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return q
    }

    func read(_ item: KeychainItem) async -> (OSStatus, Data?) {
        var q = Self.query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return (status, out as? Data)
    }

    func add(_ item: KeychainItem, data: Data) async -> OSStatus {
        SecItemAdd(Self.addAttributes(item, data: data) as CFDictionary, nil)
    }

    func update(_ item: KeychainItem, data: Data) async -> OSStatus {
        let changes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemUpdate(Self.query(item) as CFDictionary, changes as CFDictionary)
    }

    func delete(_ item: KeychainItem) async -> OSStatus {
        SecItemDelete(Self.query(item) as CFDictionary)
    }
}
