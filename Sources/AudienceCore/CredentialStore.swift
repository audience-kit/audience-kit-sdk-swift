import Foundation

#if canImport(Security)
import Security
#endif

/// Somewhere to keep the session's ``Credential`` between launches.
///
/// Session tokens don't expire (they are revoked), so treat them like passwords: keep them in the
/// keychain and never log them.
public protocol CredentialStore: Sendable {
    func load() throws -> Credential?
    func save(_ credential: Credential) throws
    func delete() throws
}

/// Keeps the credential in memory only, for tests and previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: Credential?

    public init(credential: Credential? = nil) {
        self.credential = credential
    }

    public func load() throws -> Credential? {
        lock.withLock { credential }
    }

    public func save(_ credential: Credential) throws {
        lock.withLock { self.credential = credential }
    }

    public func delete() throws {
        lock.withLock { credential = nil }
    }
}

/// How a credential is written to a store's bytes: JSON with a format version, `{ "v": 1, "credential": { … } }`,
/// so a store can tell an item from an older SDK (or the raw token the first SDKs kept) and treat it as nothing.
struct CredentialEnvelope: Codable {
    static let formatVersion = 1

    var v: Int
    var credential: Credential

    static func encode(_ credential: Credential) throws -> Data {
        try JSONEncoder().encode(CredentialEnvelope(v: formatVersion, credential: credential))
    }

    /// The stored credential, or `nil` when the bytes are from another format or version.
    static func decode(_ data: Data) -> Credential? {
        guard let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data),
              envelope.v == formatVersion
        else { return nil }
        return envelope.credential
    }
}

#if canImport(Security)
/// Keeps the credential in the keychain as a generic password, as a versioned JSON item (``CredentialEnvelope``).
///
/// Items are readable after first unlock, so an app woken in the background (location, push) can
/// still make authenticated calls. An item from an older format (a raw token) reads as no credential.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String
    /// Share the item between apps in this keychain access group, or `nil` for the app's default.
    public let accessGroup: String?

    public init(service: String, account: String = "session-credential", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func load() throws -> Credential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return CredentialEnvelope.decode(data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func save(_ credential: Credential) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try CredentialEnvelope.encode(credential),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        let addStatus = SecItemAdd(baseQuery.merging(attributes) { current, _ in current } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// A keychain call failed with an `OSStatus` other than "not found".
public struct KeychainError: Error, Sendable, Hashable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}
#endif
