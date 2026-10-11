import Foundation

#if canImport(Security)
import Security
#endif

/// Somewhere to keep the session token between launches.
///
/// Session tokens don't expire (they are revoked), so treat them like passwords: keep them in the
/// keychain and never log them.
public protocol TokenStore: Sendable {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

/// Keeps the token in memory only, for tests and previews.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func loadToken() throws -> String? {
        lock.withLock { token }
    }

    public func saveToken(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    public func deleteToken() throws {
        lock.withLock { token = nil }
    }
}

#if canImport(Security)
/// Keeps the token in the keychain as a generic password.
///
/// Items are readable after first unlock, so an app woken in the background (location, push) can
/// still make authenticated calls.
public struct KeychainTokenStore: TokenStore {
    public var service: String
    public var account: String
    /// Share the item between apps in this keychain access group, or `nil` for the app's default.
    public var accessGroup: String?

    public init(service: String, account: String = "session-token", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func saveToken(_ token: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        let addStatus = SecItemAdd(baseQuery.merging(attributes) { current, _ in current } as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func deleteToken() throws {
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
    public var status: OSStatus
}
#endif
