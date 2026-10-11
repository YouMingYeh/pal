import Foundation
import Security

struct AuthSession: Codable {
    struct User: Codable { let id: UUID; let email: String? }
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double
    let expiresAt: Double?
    let user: User
    enum CodingKeys: String, CodingKey {
        case user
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", expiresAt = "expires_at"
    }
}
struct StoredSession: Codable {
    let session: AuthSession
    let expires: Date
    init(_ session: AuthSession, now: Date = Date()) {
        self.session = session
        expires = session.expiresAt.map(Date.init(timeIntervalSince1970:)) ?? now.addingTimeInterval(session.expiresIn)
    }
    func needsRefresh(now: Date = Date()) -> Bool { expires.timeIntervalSince(now) < 60 }
}
struct PalFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SessionKeychain {
    private static var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pal.spike.shared", kSecAttrAccount as String: "session"]
        if let group = Bundle.main.object(forInfoDictionaryKey: "PalKeychainAccessGroup") as? String,
           !group.isEmpty, !group.contains("$(") { value[kSecAttrAccessGroup as String] = group }
        return value
    }
    private static var legacy: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.pal.spike", kSecAttrAccount as String: "session"]
    }
    private static func read(_ query: [String: Any]) -> StoredSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }
    static func load() -> StoredSession? {
        if let shared = read(query) { return shared }
        guard let existing = read(legacy) else { return nil }
        // Keep the old item until the signed app has access to the shared keychain group.
        try? save(existing)
        return existing
    }
    static func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw PalFailure(message: "Unable to save your session securely.")
            }
        } else if updated != errSecSuccess { throw PalFailure(message: "Unable to update your secure session.") }
    }
    static func clear() {
        SecItemDelete(query as CFDictionary)
        SecItemDelete(legacy as CFDictionary)
    }
}
