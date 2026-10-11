import Foundation
import Combine
import Security

@MainActor
final class PalStore: ObservableObject {
    @Published private(set) var storedSession: StoredSession? = SessionKeychain.load()
    @Published private(set) var groups: [ChatGroup] = []
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var states: [UUID: GroupState] = [:]
    @Published private(set) var profile: PalProfile?
    @Published var path: [UUID] = []
    @Published var requestedEntity: MessageCard?
    @Published var pendingInvite = UserDefaults.standard.string(forKey: "PendingPalInvite")
    @Published private(set) var outgoing: [OutgoingMessage] = PalStore.restoreOutgoing()

    private var pendingNotification: [AnyHashable: Any]? = UserDefaults.standard.dictionary(forKey: "PalPendingNotification")
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
                         token: String? = nil, auth: Bool = false, json: [String: JSONValue]? = nil) async throws -> Data {
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
        else if let json { request.httpBody = try JSONEncoder().encode(json) }
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

    func saveAppleName(_ name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try await api("/api/profile", method: "PATCH", body: ["display_name": name])
        try await loadProfile()
    }

    private func token() async throws -> String {
        guard let storedSession else { throw PalFailure(message: "Sign in to continue.") }
        if !storedSession.needsRefresh() { return storedSession.session.accessToken }
        if let shared = SessionKeychain.load(), shared.session.user.id == storedSession.session.user.id,
           shared.expires > storedSession.expires, !shared.needsRefresh() {
            self.storedSession = shared
            return shared.session.accessToken
        }
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

    func api(_ path: String, method: String = "GET", body: [String: String]? = nil, json: [String: JSONValue]? = nil) async throws -> Data {
        let owner = userID
        let data = try await request(base: configuredURL("PalAPIURL"), path: path, method: method, body: body, token: token(), json: json)
        guard userID == owner else { throw CancellationError() }
        return data
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

    @discardableResult
    func send(_ body: String, to group: ChatGroup, clientID: UUID, replyTo: UUID? = nil) async throws -> ChatMessage {
        struct Response: Decodable { let message: ChatMessage }
        var payload = ["body": body, "client_id": clientID.uuidString]
        if let replyTo { payload["reply_to_id"] = replyTo.uuidString }
        return try JSONDecoder().decode(Response.self, from: await api("/api/groups/\(group.id)/messages", method: "POST", body: payload)).message
    }

    func loadState(_ group: ChatGroup) async throws {
        states[group.id] = try JSONDecoder().decode(GroupState.self, from: await api("/api/groups/\(group.id)/state"))
    }

    func mutate(_ group: ChatGroup, action: String, data: [String: JSONValue]) async throws {
        _ = try await api("/api/groups/\(group.id)/state", method: "POST", json: ["action": .string(action), "data": .object(data)])
        try await loadState(group)
    }

    func loadProfile() async throws {
        struct Response: Decodable { let profile: PalProfile }
        profile = try JSONDecoder().decode(Response.self, from: await api("/api/profile")).profile
    }

    func saveProfile(name: String, avatarURL: String?, notifications: Bool) async throws {
        _ = try await api("/api/profile", method: "PATCH", json: ["display_name": .string(name),
            "avatar_url": avatarURL.map(JSONValue.string) ?? .null,
            "notification_preferences": .object(["enabled": .bool(notifications)])])
        try await loadProfile()
        if let token = UserDefaults.standard.string(forKey: "PalDeviceToken") {
            if notifications { try await registerDevice(token: token) }
            else { try await unregisterDevice(token: token) }
        }
    }

    func registerDevice(token: String) async throws {
        let environment = Bundle.main.object(forInfoDictionaryKey: "PalPushEnvironment") as? String ?? "sandbox"
        _ = try await api("/api/devices", method: "POST", body: ["token": token, "environment": environment])
    }

    func unregisterDevice(token: String) async throws {
        let environment = Bundle.main.object(forInfoDictionaryKey: "PalPushEnvironment") as? String ?? "sandbox"
        _ = try await api("/api/devices", method: "DELETE", body: ["token": token, "environment": environment])
    }

    func calendarStatus() async throws -> CalendarStatus {
        try JSONDecoder().decode(CalendarStatus.self, from: await api("/api/calendar/status"))
    }
    func calendarConnectURL() async throws -> URL {
        struct Response: Decodable { let url: URL }
        return try JSONDecoder().decode(Response.self, from: await api("/api/calendar/connect")).url
    }
    func disconnectCalendar() async throws { _ = try await api("/api/calendar/disconnect", method: "DELETE") }

    static func inviteCode(from url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let native = url.scheme == "pal" && url.host == "join"
        let web = url.scheme == "https" && url.host == "pal-jade.vercel.app"
        let segments = url.path.split(separator: "/")
        guard native || (web && segments.first == "join") || (web && url.path == "/invite") else { return nil }
        let queryCode = parts.queryItems?.first(where: { $0.name == "code" })?.value
        let pathCode = web && segments.count == 2 && segments.first == "join" ? String(segments[1]) : nil
        guard let code = queryCode ?? pathCode, let id = UUID(uuidString: code) else { return nil }
        return id.uuidString.lowercased()
    }

    func handleURL(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        if let code = Self.inviteCode(from: url) {
            pendingInvite = code
            UserDefaults.standard.set(code, forKey: "PendingPalInvite")
            if isSignedIn { Task { await acceptPendingInvite() } }
        } else if url.scheme == "pal", url.host == "calendar" {
            if parts.queryItems?.first(where: { $0.name == "status" })?.value == "connected" { notice = "Google Calendar connected." }
            else { error = "Google Calendar did not connect. Please try again." }
        }
    }

    func acceptPendingInvite() async {
        guard isSignedIn, let pendingInvite else { return }
        do {
            try await joinGroup(code: pendingInvite)
            if let group = groups.first(where: { $0.inviteCode == pendingInvite }) { path = [group.id] }
            self.pendingInvite = nil
            UserDefaults.standard.removeObject(forKey: "PendingPalInvite")
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func route(groupID: UUID, card: MessageCard? = nil) async -> Bool {
        do { try await loadGroups(); guard groups.contains(where: { $0.id == groupID }) else { return true }
            requestedEntity = card
            path = [groupID]
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func handleNotification(_ payload: [AnyHashable: Any]) {
        pendingNotification = payload
        if isSignedIn { Task { await acceptPendingNotification() } }
    }
    func acceptPendingNotification() async {
        let cached: [AnyHashable: Any]? = UserDefaults.standard.dictionary(forKey: "PalPendingNotification")
        guard isSignedIn, let payload = pendingNotification ?? cached, let value = payload["group_id"] as? String, let group = UUID(uuidString: value) else { return }
        let card = (payload["entity_id"] as? String).flatMap(UUID.init(uuidString:)).map { MessageCard(type: (payload["type"] as? String) == "poll" ? "choice" : (payload["type"] as? String ?? "plan"), entityID: $0, sourceID: nil) }
        guard await route(groupID: group, card: card) else { return }
        pendingNotification = nil
        UserDefaults.standard.removeObject(forKey: "PalPendingNotification")
    }
    func logout() async {
        if let token = UserDefaults.standard.string(forKey: "PalDeviceToken") {
            do { try await unregisterDevice(token: token) }
            catch { self.error = "Could not disconnect notifications. Please retry sign out. " + error.localizedDescription; return }
        }
        signOut()
    }

    private static func restoreOutgoing() -> [OutgoingMessage] {
        guard let data = UserDefaults.standard.data(forKey: "PalOutbox"), let values = try? JSONDecoder().decode([OutgoingMessage].self, from: data) else { return [] }
        return values.map { var copy = $0; copy.failed = true; return copy }
    }
    private func persistOutgoing() { UserDefaults.standard.set(try? JSONEncoder().encode(outgoing), forKey: "PalOutbox") }

    func queue(_ body: String, group: ChatGroup, replyTo: UUID?) async {
        guard let userID else { return }
        let item = OutgoingMessage(groupID: group.id, userID: userID, clientID: UUID(), body: body, replyToID: replyTo, failed: false)
        outgoing.append(item)
        persistOutgoing()
        await retry(item, group: group)
    }
    func retry(_ item: OutgoingMessage, group: ChatGroup) async {
        guard item.userID == userID else { return }
        if let index = outgoing.firstIndex(where: { $0.clientID == item.clientID }) { outgoing[index].failed = false }
        persistOutgoing()
        do {
            _ = try await send(item.body, to: group, clientID: item.clientID, replyTo: item.replyToID)
            outgoing.removeAll { $0.clientID == item.clientID }
        } catch {
            if let index = outgoing.firstIndex(where: { $0.clientID == item.clientID }) { outgoing[index].failed = true }
            self.error = error.localizedDescription
        }
        persistOutgoing()
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        SessionKeychain.clear()
        storedSession = nil
        groups = []
        states = [:]
        profile = nil
        path = []
        requestedEntity = nil
        error = nil
        notice = nil
    }
}
