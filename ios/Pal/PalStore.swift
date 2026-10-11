import Foundation
import Combine
import Security

@MainActor
final class PalStore: ObservableObject {
    @Published private(set) var storedSession: StoredSession? = SessionKeychain.load()
    @Published private(set) var groups: [ChatGroup] = []
    @Published var error: String?
    @Published var notice: String?
    @Published var pushRegistrationIssue: String?
    @Published private(set) var states: [UUID: GroupState] = [:]
    @Published var memberSummaries: [String: MemberSummary] = [:]
    @Published private(set) var typingHints: [UUID: PalTypingHint] = [:]
    @Published private(set) var cachedMessages: [UUID: [ChatMessage]] = [:]
    @Published private(set) var profile: PalProfile?
    @Published private(set) var groupsFetch = PalFetchState()
    @Published private(set) var profileFetch = PalFetchState()
    @Published private(set) var messageFetch: [UUID: PalFetchState] = [:]
    @Published private(set) var stateFetch: [UUID: PalFetchState] = [:]
    @Published private(set) var cachedCalendarStatus: CalendarStatus?
    private var calendarFetchedAt: Date?
    private let reads = PalFetchPool()
    private enum FetchResource: Hashable { case groups, profile, messages(UUID), state(UUID) }
    private var fetchActivity: [FetchResource: PalFetchState] = [:]
    private var accountGeneration = UUID()
    @Published var path: [UUID] = []
    @Published var requestedEntity: MessageCard?
    @Published var pendingInvite = UserDefaults.standard.string(forKey: "PendingPalInvite")
    @Published private(set) var outgoing: [OutgoingMessage] = PalStore.restoreOutgoing()

    private var pendingNotification: [AnyHashable: Any]? = UserDefaults.standard.dictionary(forKey: "PalPendingNotification")
    private var refreshTask: Task<StoredSession, Error>?
    private var refreshTaskID: UUID?
    private var registeredDeviceKeys = Set<String>()
    private var messageCache = PalMessageCache()
    private var stateRequests: [UUID: Int] = [:]
    private var appliedStateRequests: [UUID: Int] = [:]
    private var groupRequest = 0
    private var appliedGroupRequest = 0
    private let realtime = PalRealtime()
    private var warmupTask: Task<Void, Never>?
    private var warmupID: UUID?

    init() { PalImageCache.shared.setOwner(storedSession?.session.user.id) }

    var userID: UUID? { storedSession?.session.user.id }
    var isSignedIn: Bool { storedSession != nil }

    private func updateFetch(_ resource: FetchResource, _ update: (inout PalFetchState) -> Void) {
        var tracked = fetchActivity[resource, default: PalFetchState()]
        update(&tracked)
        fetchActivity[resource] = tracked
        let visible = tracked.presentation
        switch resource {
        case .groups: if groupsFetch != visible { groupsFetch = visible }
        case .profile: if profileFetch != visible { profileFetch = visible }
        case .messages(let id): if messageFetch[id] != visible { messageFetch[id] = visible }
        case .state(let id): if stateFetch[id] != visible { stateFetch[id] = visible }
        }
    }

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
                         token: String? = nil, auth: Bool = false, json: [String: JSONValue]? = nil, rawBody: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw PalFailure(message: "Invalid service URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if auth {
            guard let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String,
                  !key.isEmpty, !key.contains("YOUR_") else {
                throw PalFailure(message: "Set SupabasePublishableKey in ios/Config.local.xcconfig, then rebuild.")
            }
            request.setValue(key, forHTTPHeaderField: "apikey")
        }
        if let rawBody { request.httpBody = rawBody }
        else if let body { request.httpBody = try JSONEncoder().encode(body) }
        else if let json { request.httpBody = try JSONEncoder().encode(json) }
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { if PalCancellation.isCancellation(error) { throw CancellationError() }; throw error }
        try Task.checkCancellation()
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
        applySession(value)
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
        applySession(value)
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
        let generation = accountGeneration, taskID = UUID()
        let task = Task { () throws -> StoredSession in
            let data = try await request(base: configuredURL("SupabaseURL"), path: "/auth/v1/token?grant_type=refresh_token",
                                         method: "POST", body: ["refresh_token": storedSession.session.refreshToken], auth: true)
            let refreshed = StoredSession(try JSONDecoder().decode(AuthSession.self, from: data))
            try Task.checkCancellation()
            guard userID == storedSession.session.user.id, accountGeneration == generation else { throw CancellationError() }
            try SessionKeychain.save(refreshed)
            self.storedSession = refreshed
            return refreshed
        }
        refreshTask = task
        refreshTaskID = taskID
        defer { if refreshTaskID == taskID { refreshTask = nil; refreshTaskID = nil } }
        return try await task.value.session.accessToken
    }

    func api(_ path: String, method: String = "GET", body: [String: String]? = nil, json: [String: JSONValue]? = nil) async throws -> Data {
        let owner = userID, generation = accountGeneration
        let operation = { [self] in
            let authorization = try await token()
            guard userID == owner, accountGeneration == generation else { throw CancellationError() }
            let data = try await request(base: configuredURL("PalAPIURL"), path: path, method: method, body: body, token: authorization, json: json)
            guard userID == owner, accountGeneration == generation else { throw CancellationError() }
            return data
        }
        let data: Data
        if method == "GET" { data = try await reads.value(for: (owner?.uuidString ?? "") + path, operation: operation) }
        else { data = try await operation(); invalidateReads(after: path, json: json) }
        try Task.checkCancellation()
        guard userID == owner, accountGeneration == generation else { throw CancellationError() }
        return data
    }

    private func invalidateReads(after path: String, json: [String: JSONValue]? = nil) {
        let parts = path.split(separator: "/")
        if parts.count >= 3, parts[0] == "api", parts[1] == "groups", UUID(uuidString: String(parts[2])) != nil {
            let base = "/api/groups/" + String(parts[2])
            if case .string("group.read")? = json?["action"] {
                reads.invalidate { $0.hasSuffix("/api/groups") || $0.hasSuffix(base + "/state") }
            } else {
                reads.invalidate { $0.hasSuffix("/api/groups") || $0.contains(base + "/") }
            }
        } else if path.hasPrefix("/api/profile") {
            reads.invalidate { $0.hasSuffix("/api/profile") || $0.hasSuffix("/api/groups") || $0.hasSuffix("/state") }
        } else if path.hasPrefix("/api/calendar") {
            reads.invalidate { $0.hasSuffix("/api/calendar/status") }
        } else if path.hasPrefix("/api/groups") {
            reads.invalidate { $0.hasSuffix("/api/groups") }
        }
    }

    func report(_ error: Error) {
        guard !PalCancellation.isCancellation(error) else { return }
        self.error = error.localizedDescription
    }

    func loadGroups() async throws {
        let generation = accountGeneration
        updateFetch(.groups) { $0.begin() }
        do {
        groupRequest += 1
        let sequence = groupRequest
        struct Response: Decodable { let groups: [ChatGroup] }
        var loaded = try JSONDecoder().decode(Response.self, from: await api("/api/groups")).groups
        guard sequence >= appliedGroupRequest else { updateFetch(.groups) { $0.finish() }; return }
        appliedGroupRequest = sequence
        let changed = loaded.filter { messageCache.needsRefresh(groupID: $0.id, latestMessageID: $0.lastMessage?.id) }
        for index in loaded.indices {
            if let message = messageCache.latestAcknowledgement(groupID: loaded[index].id),
               (PalDate.date(message.createdAt) ?? .distantPast) > ((loaded[index].lastMessage?.createdAt).flatMap(PalDate.date) ?? .distantPast) {
                loaded[index].lastMessage = GroupLastMessage(id: message.id, body: message.body, createdAt: message.createdAt, role: message.role)
            }
        }
        if groups != loaded { groups = loaded }
        let allowed = Set(loaded.map(\.id))
        messageCache.prune(groupIDs: allowed)
        if cachedMessages != messageCache.messages { cachedMessages = messageCache.messages }
        if states.keys.contains(where: { !allowed.contains($0) }) { states = states.filter { allowed.contains($0.key) } }
        let retainedSummaries = memberSummaries.filter { entry in
            entry.key.split(separator: "/").first.flatMap { UUID(uuidString: String($0)) }.map { allowed.contains($0) } == true
        }
        if retainedSummaries.count != memberSummaries.count { memberSummaries = retainedSummaries }
        if stateFetch.keys.contains(where: { !allowed.contains($0) }) { stateFetch = stateFetch.filter { allowed.contains($0.key) } }
        if messageFetch.keys.contains(where: { !allowed.contains($0) }) { messageFetch = messageFetch.filter { allowed.contains($0.key) } }
        if typingHints.keys.contains(where: { !allowed.contains($0) }) { typingHints = typingHints.filter { allowed.contains($0.key) } }
        fetchActivity = fetchActivity.filter { resource, _ in
            switch resource { case .messages(let id), .state(let id): return allowed.contains(id); case .groups, .profile: return true }
        }
        if let open = path.last, !allowed.contains(open) { path = []; requestedEntity = nil }
        warmHistory(loaded.filter { group in states[group.id] == nil || changed.contains(where: { $0.id == group.id }) })
        updateFetch(.groups) { $0.finish() }
        } catch { if accountGeneration == generation { updateFetch(.groups) { $0.fail(error) } }; throw error }
    }

    func createGroup(name: String, avatarData: Data? = nil, clientID: UUID = UUID()) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 80 else { throw PalFailure(message: "Use a group name with 1 to 80 characters.") }
        let data: Data
        if let avatarData {
            guard !avatarData.isEmpty, avatarData.count <= 2 * 1024 * 1024 else { throw PalFailure(message: "Choose a photo smaller than 2 MB.") }
            data = try await multipart(path: "/api/groups", fields: ["name": name, "client_id": clientID.uuidString], file: avatarData, filename: "group.jpg", mimeType: "image/jpeg")
        } else { data = try await api("/api/groups", method: "POST", body: ["name": name, "client_id": clientID.uuidString]) }
        struct Response: Decodable { let group: ChatGroup }
        let group = try JSONDecoder().decode(Response.self, from: data).group
        try await loadGroups()
        path = [group.id]
    }

    private func multipart(path: String, fields: [String: String], file: Data, filename: String, mimeType: String) async throws -> Data {
        let owner = userID
        let boundary = "PalMedia-" + UUID().uuidString
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(file); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await request(base: configuredURL("PalAPIURL"), path: path, method: "POST", token: token(), rawBody: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard userID == owner else { throw CancellationError() }
        invalidateReads(after: path)
        return data
    }

    @discardableResult
    func sendAttachment(_ attachment: DraftAttachment, body: String, to group: ChatGroup, clientID: UUID, replyTo: UUID?, mentions: [MessageMention] = []) async throws -> ChatMessage {
        let file = try Data(contentsOf: AttachmentFiles.url(for: attachment))
        guard file.count == attachment.byteSize, file.count > 0,
              file.count <= (attachment.kind == "image" ? 2 : 4) * 1024 * 1024 else { throw PalFailure(message: "This attachment is unavailable. Please select it again.") }
        var fields = ["body": body, "client_id": clientID.uuidString, "kind": attachment.kind]
        if let replyTo { fields["reply_to_id"] = replyTo.uuidString }
        if !mentions.isEmpty { fields["mentions"] = String(decoding: try JSONEncoder().encode(mentions), as: UTF8.self) }
        let data = try await multipart(path: "/api/groups/\(group.id)/attachments", fields: fields, file: file, filename: attachment.filename, mimeType: attachment.mimeType)
        struct Response: Decodable { let message: ChatMessage }
        let message = try JSONDecoder().decode(Response.self, from: data).message
        acknowledge(message)
        return message
    }

    func joinGroup(code: String) async throws {
        guard let invite = Self.inviteCode(from: code) else { throw PalFailure(message: "Paste a Pal invite link or valid invite code.") }
        struct Response: Decodable { let group: ChatGroup }
        let group = try JSONDecoder().decode(Response.self, from: await api("/api/groups/join", method: "POST", body: ["invite_code": invite])).group
        try await loadGroups()
        path = [group.id]
    }

    static func inviteCode(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: value) { return uuid.uuidString.lowercased() }
        return URL(string: value).flatMap { inviteCode(from: $0) }
    }

    func messages(in group: ChatGroup) async throws -> [ChatMessage] {
        let generation = accountGeneration
        updateFetch(.messages(group.id)) { $0.begin() }
        do {
        let sequence = messageCache.beginFetch(groupID: group.id)
        struct Response: Decodable { let messages: [ChatMessage] }
        let loaded = try JSONDecoder().decode(Response.self, from: await api("/api/groups/\(group.id)/messages")).messages
        let merged = messageCache.acceptSnapshot(loaded, groupID: group.id, sequence: sequence)
        if cachedMessages != messageCache.messages { cachedMessages = messageCache.messages }
        reconcileOutgoing(with: merged)
        updateFetch(.messages(group.id)) { $0.finish() }
        return merged
        } catch { if accountGeneration == generation { updateFetch(.messages(group.id)) { $0.fail(error) } }; throw error }
    }

    @discardableResult
    func send(_ body: String, to group: ChatGroup, clientID: UUID, replyTo: UUID? = nil, mentions: [MessageMention] = []) async throws -> ChatMessage {
        struct Response: Decodable { let message: ChatMessage }
        var payload: [String: JSONValue] = ["body": .string(body), "client_id": .string(clientID.uuidString)]
        if let replyTo { payload["reply_to_id"] = .string(replyTo.uuidString) }
        if !mentions.isEmpty { payload["mentions"] = .array(mentions.map { mention in
            var item: [String: JSONValue] = ["type": .string(mention.type)]
            if let userID = mention.userID { item["user_id"] = .string(userID.uuidString) }
            return .object(item)
        }) }
        let message = try JSONDecoder().decode(Response.self, from: await api("/api/groups/\(group.id)/messages", method: "POST", json: payload)).message
        acknowledge(message)
        return message
    }

    func loadState(_ group: ChatGroup) async throws {
        let generation = accountGeneration
        updateFetch(.state(group.id)) { $0.begin() }
        do {
        let sequence = (stateRequests[group.id] ?? 0) + 1
        stateRequests[group.id] = sequence
        let loaded = try JSONDecoder().decode(GroupState.self, from: await api("/api/groups/\(group.id)/state"))
        guard sequence >= (appliedStateRequests[group.id] ?? 0) else { updateFetch(.state(group.id)) { $0.finish() }; return }
        appliedStateRequests[group.id] = sequence
        if states[group.id] != loaded { states[group.id] = loaded }
        let memberKeys = Set(loaded.members.map { MemberSummary.key(groupID: group.id, userID: $0.userID) })
        let retainedSummaries = memberSummaries.filter { !$0.key.hasPrefix(group.id.uuidString + "/") || memberKeys.contains($0.key) }
        if retainedSummaries.count != memberSummaries.count { memberSummaries = retainedSummaries }
        if typingHints[group.id]?.acceptsState(sequence: sequence) == true { typingHints[group.id] = nil }
        updateFetch(.state(group.id)) { $0.finish() }
        } catch { if accountGeneration == generation { updateFetch(.state(group.id)) { $0.fail(error) } }; throw error }
    }

    func mutate(_ group: ChatGroup, action: String, data: [String: JSONValue]) async throws {
        let response = try await api("/api/groups/\(group.id)/state", method: "POST", json: ["action": .string(action), "data": .object(data)])
        if action == "group.read" {
            if let index = groups.firstIndex(where: { $0.id == group.id }), groups[index].unreadCount != 0 { groups[index].unreadCount = 0 }
            if case .string(let value)? = data["message_id"], let messageID = UUID(uuidString: value),
               let receipt = try? JSONDecoder().decode(PalReadReceipt.self, from: response),
               var state = states[group.id], let member = state.members.firstIndex(where: { $0.userID == userID }) {
                let createdAt = cachedMessages[group.id]?.first { $0.id == messageID }?.createdAt
                receipt.apply(to: &state.members[member], messageID: messageID, targetCreatedAt: createdAt)
                if states[group.id] != state { states[group.id] = state }
            }
            return
        }
        try await loadState(group)
    }

    func loadProfile() async throws {
        let generation = accountGeneration
        updateFetch(.profile) { $0.begin() }
        do {
            struct Response: Decodable { let profile: PalProfile }
            let loaded = try JSONDecoder().decode(Response.self, from: await api("/api/profile")).profile
            if profile != loaded { profile = loaded }
            updateFetch(.profile) { $0.finish() }
        } catch { if accountGeneration == generation { updateFetch(.profile) { $0.fail(error) } }; throw error }
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

    func uploadAvatar(data: Data, displayName: String? = nil) async throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw PalFailure(message: "Choose a photo smaller than 2 MB.") }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.isEmpty || name.utf16.count > 60 { throw PalFailure(message: "Use a name with 1 to 60 characters.") }
        let owner = userID
        let boundary = "PalAvatar-" + UUID().uuidString
        var body = Data()
        if let name { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"display_name\"\r\n\r\n\(name)\r\n".utf8)) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await request(base: configuredURL("PalAPIURL"), path: "/api/profile/avatar", method: "POST", token: token(), rawBody: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard userID == owner else { throw CancellationError() }
        struct Response: Decodable { let profile: PalProfile }
        profile = try JSONDecoder().decode(Response.self, from: response).profile
        invalidateReads(after: "/api/profile/avatar")
    }

    func registerDevice(token: String) async throws {
        let environment = Bundle.main.object(forInfoDictionaryKey: "PalPushEnvironment") as? String ?? "sandbox"
        guard let owner = userID else { throw PalFailure(message: "Sign in to enable notifications.") }
        let key = owner.uuidString + ":" + environment + ":" + token
        guard !registeredDeviceKeys.contains(key) else { return }
        _ = try await api("/api/devices", method: "POST", body: ["token": token, "environment": environment])
        registeredDeviceKeys.insert(key)
        pushRegistrationIssue = nil
    }

    func recordPushRegistrationError(_ description: String) {
        pushRegistrationIssue = description
    }

    func unregisterDevice(token: String) async throws {
        let environment = Bundle.main.object(forInfoDictionaryKey: "PalPushEnvironment") as? String ?? "sandbox"
        let owner = userID
        _ = try await api("/api/devices", method: "DELETE", body: ["token": token, "environment": environment])
        if let owner { registeredDeviceKeys.remove(owner.uuidString + ":" + environment + ":" + token) }
    }

    func calendarStatus(force: Bool = false) async throws -> CalendarStatus {
        if !force, let status = cachedCalendarStatus, let date = calendarFetchedAt, Date().timeIntervalSince(date) < 30 { return status }
        let value = try JSONDecoder().decode(CalendarStatus.self, from: await api("/api/calendar/status"))
        cachedCalendarStatus = value; calendarFetchedAt = Date()
        return value
    }
    func calendarConnectURL() async throws -> URL {
        struct Response: Decodable { let url: URL }
        return try JSONDecoder().decode(Response.self, from: await api("/api/calendar/connect")).url
    }
    func disconnectCalendar() async throws {
        _ = try await api("/api/calendar/disconnect", method: "DELETE")
        cachedCalendarStatus = nil; calendarFetchedAt = nil
    }

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
        } else if let route = Self.calendarPlanRoute(from: url) {
            let payload = ["group_id": route.groupID.uuidString, "entity_id": route.planID.uuidString, "type": "plan"]
            UserDefaults.standard.set(payload, forKey: "PalPendingNotification")
            handleNotification(payload)
        } else if url.scheme == "pal", url.host == "calendar" {
            if parts.queryItems?.first(where: { $0.name == "status" })?.value == "connected" { notice = "Google Calendar connected." }
            else { error = "Google Calendar did not connect. Please try again." }
        }
    }

    static func calendarPlanRoute(from url: URL) -> (groupID: UUID, planID: UUID)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == "pal", url.host == "group", url.user == nil, url.password == nil,
              let first = parts.first, let groupID = UUID(uuidString: first) else { return nil }
        let planValue: String?
        if parts.count == 3, parts[1] == "plan" { planValue = parts[2] }
        else if parts.count == 1 { planValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "plan" }?.value }
        else { return nil }
        guard let planValue, let planID = UUID(uuidString: planValue) else { return nil }
        return (groupID, planID)
    }

    func acceptPendingInvite() async {
        guard isSignedIn, let pendingInvite else { return }
        do {
            try await joinGroup(code: pendingInvite)
            if let group = groups.first(where: { $0.inviteCode == pendingInvite }) { path = [group.id] }
            self.pendingInvite = nil
            UserDefaults.standard.removeObject(forKey: "PendingPalInvite")
        } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
    }

    @discardableResult
    func route(groupID: UUID, card: MessageCard? = nil) async -> Bool {
        do { try await loadGroups(); guard groups.contains(where: { $0.id == groupID }) else { return true }
            requestedEntity = card
            path = [groupID]
            return true
        } catch { report(error); return false }
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
            catch { if !PalCancellation.isCancellation(error) { self.error = "Could not disconnect notifications. Please retry sign out. " + error.localizedDescription }; return }
        }
        signOut()
    }

    private func applySession(_ value: StoredSession) {
        if userID != value.session.user.id { clearReadCache() }
        storedSession = value
        PalImageCache.shared.setOwner(value.session.user.id)
    }

    private func clearReadCache() {
        accountGeneration = UUID()
        reads.clear()
        fetchActivity.removeAll()
        refreshTask?.cancel(); refreshTask = nil; refreshTaskID = nil
        warmupID = nil; warmupTask?.cancel(); warmupTask = nil
        groups = []; states = [:]; memberSummaries = [:]; messageCache.clear(); cachedMessages = [:]; typingHints = [:]
        groupsFetch = PalFetchState(); profileFetch = PalFetchState(); stateFetch = [:]; messageFetch = [:]
        profile = nil; cachedCalendarStatus = nil; calendarFetchedAt = nil
        path = []; requestedEntity = nil
    }

    private static func restoreOutgoing() -> [OutgoingMessage] {
        guard let data = UserDefaults.standard.data(forKey: "PalOutbox"), let values = try? JSONDecoder().decode([OutgoingMessage].self, from: data) else { return [] }
        return values.map { var copy = $0; copy.failed = true; return copy }
    }
    private func persistOutgoing() { UserDefaults.standard.set(try? JSONEncoder().encode(outgoing), forKey: "PalOutbox") }

    func queue(_ body: String, group: ChatGroup, replyTo: UUID?, attachment: DraftAttachment? = nil, mentions: [MessageMention] = []) async {
        guard let userID else { return }
        let item = OutgoingMessage(groupID: group.id, userID: userID, clientID: UUID(), body: body, replyToID: replyTo, failed: false, attachment: attachment, createdAt: PalDate.iso(Date()), mentions: mentions)
        outgoing.append(item)
        persistOutgoing()
        await retry(item, group: group)
    }
    func retry(_ item: OutgoingMessage, group: ChatGroup) async {
        guard item.userID == userID else { return }
        if states[group.id]?.settings?.agentPaused != true { typingHints[group.id] = PalTypingHint(clientID: item.clientID) }
        if let index = outgoing.firstIndex(where: { $0.clientID == item.clientID }) { outgoing[index].failed = false }
        persistOutgoing()
        do {
            if let attachment = item.attachment {
                _ = try await sendAttachment(attachment, body: item.body, to: group, clientID: item.clientID, replyTo: item.replyToID, mentions: item.mentions ?? [])
                try? AttachmentFiles.remove(attachment)
            } else { _ = try await send(item.body, to: group, clientID: item.clientID, replyTo: item.replyToID, mentions: item.mentions ?? []) }
            outgoing.removeAll { $0.clientID == item.clientID }
        } catch {
            if typingHints[group.id]?.clientID == item.clientID { typingHints[group.id] = nil }
            if let index = outgoing.firstIndex(where: { $0.clientID == item.clientID }) { outgoing[index].failed = true; report(error) }
        }
        persistOutgoing()
    }

    func reconcileOutgoing(with messages: [ChatMessage]) {
        let received = Set(messages.compactMap(\.clientID))
        let delivered = outgoing.filter { $0.userID == userID && received.contains($0.clientID) }
        guard !delivered.isEmpty else { return }
        for item in delivered { if let attachment = item.attachment { try? AttachmentFiles.remove(attachment) } }
        outgoing.removeAll { $0.userID == userID && received.contains($0.clientID) }
        persistOutgoing()
    }

    func signOut() {
        clearReadCache()
        PalImageCache.shared.setOwner(nil)
        warmupID = nil
        warmupTask?.cancel()
        warmupTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        registeredDeviceKeys.removeAll()
        SessionKeychain.clear()
        storedSession = nil
        groups = []
        states = [:]
        memberSummaries = [:]
        messageCache.clear()
        cachedMessages = [:]
        typingHints = [:]
        profile = nil
        path = []
        requestedEntity = nil
        error = nil
        notice = nil
    }

    private func warmHistory(_ changed: [ChatGroup]) {
        guard warmupTask == nil, let owner = userID else { return }
        let allowed = Set(groups.map(\.id))
        let unknown = changed.filter { allowed.contains($0.id) }
        guard !unknown.isEmpty else { return }
        let generation = UUID()
        warmupID = generation
        warmupTask = Task {
            defer { if warmupID == generation { warmupTask = nil; warmupID = nil } }
            await withTaskGroup(of: Void.self) { tasks in
                var iterator = unknown.makeIterator()
                func add(_ group: ChatGroup) {
                    tasks.addTask { @MainActor [weak self] in
                        guard let self, self.userID == owner, !Task.isCancelled else { return }
                        async let history = self.messages(in: group)
                        async let details: Void = self.loadState(group)
                        _ = try? await history
                        _ = try? await details
                        guard self.userID == owner, !Task.isCancelled else { return }
                        let photos = ([group.avatarURL] + (self.states[group.id]?.members ?? []).map(\.avatarURL)).compactMap { $0 }.compactMap(URL.init(string:))
                        await withTaskGroup(of: Void.self) { images in
                            for url in Set(photos) { images.addTask { @MainActor in _ = try? await PalImageCache.shared.image(url) } }
                        }
                    }
                }
                for _ in 0..<2 { if let group = iterator.next() { add(group) } }
                while await tasks.next() != nil {
                    guard !Task.isCancelled, userID == owner else { tasks.cancelAll(); return }
                    if let group = iterator.next() { add(group) }
                }
            }
        }
    }

    private func acknowledge(_ message: ChatMessage) {
        messageCache.acknowledge(message)
        if cachedMessages != messageCache.messages { cachedMessages = messageCache.messages }
        if message.role == "user", typingHints[message.groupID]?.clientID == message.clientID {
            typingHints[message.groupID]?.posted(after: stateRequests[message.groupID] ?? 0)
        }
        if let index = groups.firstIndex(where: { $0.id == message.groupID }) {
            let latest = GroupLastMessage(id: message.id, body: message.body, createdAt: message.createdAt, role: message.role)
            if groups[index].lastMessage != latest { groups[index].lastMessage = latest }
        }
    }

    func isPalTyping(in groupID: UUID, at now: Date = Date()) -> Bool {
        guard states[groupID]?.settings?.agentPaused != true else { return false }
        return typingHints[groupID]?.isVisible(at: now) == true || states[groupID]?.palActivity?.isThinking(at: now) == true
    }
    func typingDeadline(in groupID: UUID) -> Date? {
        [typingHints[groupID]?.expiresAt, states[groupID]?.palActivity?.expiresAt.flatMap(PalDate.date)].compactMap { $0 }.max()
    }

    var realtimeIdentity: String {
        (userID?.uuidString ?? "signed-out") + ":" + groups.map { $0.id.uuidString }.sorted().joined(separator: ",")
    }

    func runRealtime() async {
        // A changed group list can start its replacement task before the cancelled socket finishes teardown.
        while realtime.isRunning && !Task.isCancelled { do { try await Task.sleep(for: .milliseconds(20)) } catch { return } }
        guard !Task.isCancelled else { return }
        guard let owner = userID, let url = try? configuredURL("SupabaseURL"),
              let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String else { return }
        await realtime.run(url: url, key: key, groupIDs: groups.map(\.id), token: { [weak self] in
            guard let self, self.userID == owner else { throw CancellationError() }
            return try await self.token()
        }, onChange: { [weak self] groupID in
            guard let self, self.userID == owner, !Task.isCancelled else { return }
            // Realtime is an invalidation signal. Only the authenticated API enters the cache.
            if let group = self.groups.first(where: { $0.id == groupID }), groupID == self.path.last {
                _ = try? await self.messages(in: group)
                try? await self.loadState(group)
            } else if groupID == nil, let group = self.groups.first(where: { $0.id == self.path.last }) {
                _ = try? await self.messages(in: group)
                try? await self.loadState(group)
            }
            try? await self.loadGroups()
        })
    }
}
