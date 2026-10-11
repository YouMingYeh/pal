import Foundation
import Combine
import Security

struct ChatGroup: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let inviteCode: String
    enum CodingKeys: String, CodingKey { case id, name; case inviteCode = "invite_code" }
}

struct ChatMessage: Decodable, Identifiable {
    let id: UUID
    let groupID: UUID
    let senderID: UUID?
    let role: String
    let body: String
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, role, body
        case groupID = "group_id", senderID = "sender_id", createdAt = "created_at"
    }
}

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

private enum SessionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.pal.spike",
         kSecAttrAccount as String: "session"]
    }
    static func load() -> StoredSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
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
        } else if updated != errSecSuccess {
            throw PalFailure(message: "Unable to update your secure session.")
        }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor
final class PalStore: ObservableObject {
    @Published private(set) var storedSession: StoredSession? = SessionKeychain.load()
    @Published private(set) var groups: [ChatGroup] = []
    @Published var error: String?
    @Published var notice: String?
    private var refreshTask: Task<StoredSession, Error>?

    var userID: UUID? { storedSession?.session.user.id }
    var isSignedIn: Bool { storedSession != nil }

    private func configuredURL(_ key: String) throws -> URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.contains("YOUR_"), let url = URL(string: value),
              let host = url.host,
              url.scheme == "https" || (key == "PalAPIURL" && url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else {
            throw PalFailure(message: "Set \(key) in ios/Config.local.xcconfig, then rebuild.")
        }
        return url
    }

    private func request(base: URL, path: String, method: String = "GET", body: [String: String]? = nil,
                         token: String? = nil, auth: Bool = false) async throws -> Data {
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw PalFailure(message: "Invalid service URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if auth {
            guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
                  !key.isEmpty, !key.contains("YOUR_") else {
                throw PalFailure(message: "Set SupabasePublishableKey in ios/Config.local.xcconfig, then rebuild.")
            }
            request.setValue(key, forHTTPHeaderField: "apikey")
        }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PalFailure(message: "No server response.") }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ["error_description", "msg", "message", "error"].compactMap { object?[$0] as? String }.first
            throw PalFailure(message: message ?? "Request failed (\(response.statusCode)).")
        }
        return data
    }

    func authenticate(email: String, password: String, signUp: Bool) async throws {
        let path = signUp ? "/auth/v1/signup" : "/auth/v1/token?grant_type=password"
        let data = try await request(base: configuredURL("SupabaseURL"), path: path, method: "POST",
                                     body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password], auth: true)
        if signUp, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["access_token"] == nil {
            notice = "Check your email to confirm your account, then sign in."
            return
        }
        let value = StoredSession(try JSONDecoder().decode(AuthSession.self, from: data))
        try SessionKeychain.save(value)
        storedSession = value
        notice = nil
    }

    func authenticateApple(identityToken: Data?, nonce: String) async throws {
        guard !nonce.isEmpty, let identityToken,
              let token = String(data: identityToken, encoding: .utf8), !token.isEmpty else {
            throw PalFailure(message: "Apple did not return a valid sign-in. Please try again.")
        }
        let data = try await request(base: configuredURL("SupabaseURL"), path: "/auth/v1/token?grant_type=id_token",
                                     method: "POST", body: ["provider": "apple", "id_token": token, "nonce": nonce], auth: true)
        let value = StoredSession(try JSONDecoder().decode(AuthSession.self, from: data))
        try SessionKeychain.save(value)
        storedSession = value
        notice = nil
    }

    private func token() async throws -> String {
        guard let storedSession else { throw PalFailure(message: "Sign in to continue.") }
        if !storedSession.needsRefresh() { return storedSession.session.accessToken }
        if let refreshTask { return try await refreshTask.value.session.accessToken }
        let task = Task { () throws -> StoredSession in
            let data = try await request(base: configuredURL("SupabaseURL"), path: "/auth/v1/token?grant_type=refresh_token",
                                         method: "POST", body: ["refresh_token": storedSession.session.refreshToken], auth: true)
            let refreshed = StoredSession(try JSONDecoder().decode(AuthSession.self, from: data))
            try Task.checkCancellation()
            try SessionKeychain.save(refreshed)
            self.storedSession = refreshed
            return refreshed
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.session.accessToken
    }

    private func api(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        try await request(base: configuredURL("PalAPIURL"), path: path, method: method, body: body, token: token())
    }

    func loadGroups() async throws {
        struct Response: Decodable { let groups: [ChatGroup] }
        groups = try JSONDecoder().decode(Response.self, from: await api("/api/groups")).groups
    }

    func createGroup(name: String) async throws {
        _ = try await api("/api/groups", method: "POST", body: ["name": name])
        try await loadGroups()
    }

    func joinGroup(code: String) async throws {
        _ = try await api("/api/groups/join", method: "POST", body: ["invite_code": code.trimmingCharacters(in: .whitespacesAndNewlines)])
        try await loadGroups()
    }

    func messages(in group: ChatGroup) async throws -> [ChatMessage] {
        struct Response: Decodable { let messages: [ChatMessage] }
        return try JSONDecoder().decode(Response.self, from: await api("/api/groups/\(group.id)/messages")).messages
    }

    func send(_ body: String, to group: ChatGroup, clientID: UUID) async throws {
        _ = try await api("/api/groups/\(group.id)/messages", method: "POST", body: ["body": body, "client_id": clientID.uuidString])
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        SessionKeychain.clear()
        storedSession = nil
        groups = []
        error = nil
        notice = nil
    }
}
