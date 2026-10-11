import Foundation

// Phoenix JSON protocol v1: https://supabase.com/docs/guides/realtime/protocol
// Authenticated INSERTs can fill new text bubbles immediately. API refreshes still
// reconcile attachments, replies, edits, removals and current membership.
@MainActor final class PalRealtime {
    private(set) var isRunning = false
    private(set) var activeSocket: URLSessionWebSocketTask?
    private(set) var isHeartbeatRunning = false

    func run(url: URL, key: String, groupIDs: [UUID],
             token: @escaping () async throws -> String,
             onReady: (() async -> Void)? = nil,
             onMessage: ((ChatMessage) -> Void)? = nil,
             onChange: @escaping (UUID?) async -> Void) async {
        guard !isRunning, !Task.isCancelled, !groupIDs.isEmpty,
              let endpoint = try? PalRealtimeProtocol.endpoint(url: url, key: key) else { return }
        isRunning = true
        let session = URLSession(configuration: .ephemeral)
        let lifetime = RealtimeSocketLifetime(session: session)
        defer {
            lifetime.cancel()
            session.invalidateAndCancel()
            activeSocket = nil
            isHeartbeatRunning = false
            isRunning = false
        }
        await withTaskCancellationHandler {
            var failures = 0
            while !Task.isCancelled {
                var ready = false
                do {
                    let accessToken = try await token()
                    try Task.checkCancellation()
                    guard !accessToken.isEmpty else { throw URLError(.userAuthenticationRequired) }
                    let socket = session.webSocketTask(with: endpoint)
                    socket.maximumMessageSize = 512 * 1024
                    let connection = Connection(socket: socket, token: accessToken, groupIDs: Set(groupIDs))
                    activeSocket = socket
                    lifetime.attach(socket)
                    socket.resume()
                    try await RealtimeWebSocket.send(PalRealtimeProtocol.join(token: accessToken, ref: connection.joinRef, groupIDs: groupIDs), on: socket)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { @MainActor in
                            try await self.receive(connection, onMessage: onMessage)
                        }
                        group.addTask { @MainActor in
                            try await self.heartbeat(connection, token: token)
                        }
                        group.addTask { @MainActor in
                            await self.refresh(connection, onReady: onReady, onChange: onChange)
                        }
                        do { _ = try await group.next() }
                        catch {
                            group.cancelAll()
                            socket.cancel()
                            ready = connection.ready
                            throw error
                        }
                        group.cancelAll()
                        socket.cancel()
                        ready = connection.ready
                    }
                } catch {
                    // Connectivity, expired authentication and channel errors recover silently.
                    // Do not log errors: Foundation errors may contain the request URL.
                }
                activeSocket?.cancel()
                activeSocket = nil
                lifetime.detach()
                guard !Task.isCancelled else { break }
                failures = ready ? 0 : min(failures + 1, 6)
                do {
                    try await Task.sleep(for: .seconds(PalRealtimeProtocol.reconnectDelay(failures: failures)))
                } catch { break }
            }
        } onCancel: {
            // Closing directly also interrupts a receive suspended inside URLSession.
            lifetime.cancel()
        }
    }

    private func receive(_ connection: Connection, onMessage: ((ChatMessage) -> Void)?) async throws {
        defer { connection.changesContinuation.finish() }
        while !Task.isCancelled {
            let message = try await RealtimeWebSocket.receive(on: connection.socket)
            try Task.checkCancellation()
            let text: String
            switch message {
            case .string(let string): text = string
            case .data(let data):
                guard let string = String(data: data, encoding: .utf8) else { continue }
                text = string
            @unknown default: continue
            }
            switch PalRealtimeProtocol.incoming(text, joinRef: connection.joinRef, heartbeatRef: connection.heartbeatRef) {
            case .joined:
                if !connection.joined {
                    connection.joined = true
                    connection.enqueue(nil) // Catch changes missed while disconnected or backgrounded.
                }
            case .heartbeat:
                connection.heartbeatRef = nil
            case .ready:
                if connection.joined, !connection.ready {
                    connection.ready = true
                    connection.readyCallbackPending = true
                    connection.enqueue(nil) // Readiness can follow channel join after a separate delay.
                }
            case .change(let groupID):
                if connection.joined, groupID.map(connection.groupIDs.contains) ?? true {
                    if let message = PalRealtimeProtocol.insertedMessage(text, groupIDs: connection.groupIDs) { onMessage?(message) }
                    connection.enqueue(groupID)
                }
            case .reconnect: throw URLError(.networkConnectionLost)
            case .ignored: break
            }
        }
        throw CancellationError()
    }

    private func refresh(_ connection: Connection, onReady: (() async -> Void)?, onChange: @escaping (UUID?) async -> Void) async {
        // One structured worker coalesces bursts while receive and heartbeat keep
        // draining the socket. Cancelling the connection cancels this worker too.
        for await _ in connection.changes {
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            guard !Task.isCancelled else { return }
            guard connection.pendingAll || !connection.pendingGroups.isEmpty || connection.readyCallbackPending else { continue }
            let groupID = connection.pendingAll || connection.pendingGroups.count != 1 ? nil : connection.pendingGroups.first
            connection.pendingAll = false
            connection.pendingGroups.removeAll()
            let notifyReady = connection.readyCallbackPending
            connection.readyCallbackPending = false
            await onChange(groupID)
            guard !Task.isCancelled else { return }
            if notifyReady { await onReady?() }
        }
    }

    private func heartbeat(_ connection: Connection, token: @escaping () async throws -> String) async throws {
        isHeartbeatRunning = true
        defer { isHeartbeatRunning = false }
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(25))
            try Task.checkCancellation()
            guard connection.joined, connection.heartbeatRef == nil else { throw URLError(.timedOut) }
            let ref = UUID().uuidString
            connection.heartbeatRef = ref
            try await RealtimeWebSocket.send(PalRealtimeProtocol.heartbeat(ref: ref), on: connection.socket)
            let refreshed = try await token()
            try Task.checkCancellation()
            guard !refreshed.isEmpty else { throw URLError(.userAuthenticationRequired) }
            if refreshed != connection.token {
                try await RealtimeWebSocket.send(PalRealtimeProtocol.refresh(token: refreshed, ref: UUID().uuidString, joinRef: connection.joinRef), on: connection.socket)
                connection.token = refreshed
            }
        }
        throw CancellationError()
    }

    private final class Connection {
        let socket: URLSessionWebSocketTask
        let groupIDs: Set<UUID>
        let changes: AsyncStream<Void>
        let changesContinuation: AsyncStream<Void>.Continuation
        let joinRef = UUID().uuidString
        var token: String
        var joined = false
        var ready = false
        var heartbeatRef: String?
        var pendingAll = false
        var pendingGroups = Set<UUID>()
        var readyCallbackPending = false
        init(socket: URLSessionWebSocketTask, token: String, groupIDs: Set<UUID>) {
            self.socket = socket; self.token = token; self.groupIDs = groupIDs
            let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            changes = stream.stream; changesContinuation = stream.continuation
        }
        func enqueue(_ groupID: UUID?) {
            if let groupID { pendingGroups.insert(groupID) } else { pendingAll = true }
            changesContinuation.yield(())
        }
    }
}

// Foundation's async WebSocket API can remain suspended when a cancelled HTTP upgrade
// never completes. Resume independently on cancellation; ignore its eventual callback.
private enum RealtimeWebSocket {
    static func send(_ text: String, on socket: URLSessionWebSocketTask) async throws {
        let operation = RealtimeContinuation<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.attach(continuation) else { return }
                socket.send(.string(text)) { error in
                    if let error { operation.finish(.failure(error)) }
                    else { operation.finish(.success(())) }
                }
            }
        } onCancel: {
            socket.cancel()
            operation.finish(.failure(CancellationError()))
        }
    }

    static func receive(on socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        let operation = RealtimeContinuation<URLSessionWebSocketTask.Message>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.attach(continuation) else { return }
                socket.receive { result in operation.finish(result) }
            }
        } onCancel: {
            socket.cancel()
            operation.finish(.failure(CancellationError()))
        }
    }
}

private final class RealtimeContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func attach(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum PalRealtimeEvent: Equatable {
    case joined, ready, heartbeat, change(UUID?), reconnect, ignored
}

enum PalRealtimeProtocol {
    static let topic = "realtime:pal-messages"
    static let tables = ["messages", "message_attachments", "message_reactions", "sources", "places", "place_contributors", "polls", "poll_responses", "plans", "plan_rsvps", "reminders", "member_memories", "group_member_locations"]

    static func endpoint(url: URL, key: String) throws -> URL {
        guard !key.isEmpty, !key.hasPrefix("sb_secret_"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, components.user == nil, components.password == nil else { throw URLError(.badURL) }
        switch components.scheme {
        case "https", "wss": components.scheme = "wss"
        case "http", "ws":
            guard ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) else { throw URLError(.badURL) }
            components.scheme = "ws"
        default: throw URLError(.badURL)
        }
        components.path = "/realtime/v1/websocket"
        components.fragment = nil
        components.queryItems = [URLQueryItem(name: "apikey", value: key), URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let result = components.url else { throw URLError(.badURL) }
        return result
    }

    static func join(token: String, ref: String, groupIDs: [UUID]) throws -> String {
        let subscriptions: [[String: Any]] = Set(groupIDs).sorted { $0.uuidString < $1.uuidString }.flatMap { groupID in
            tables.map { table in ["event": "*", "schema": "public", "table": table, "filter": "group_id=eq.\(groupID.uuidString.lowercased())"] }
        }
        return try frame(event: "phx_join", ref: ref, joinRef: ref, payload: [
            "access_token": token,
            "config": [
                "broadcast": ["ack": false, "self": false],
                "presence": ["enabled": false],
                "private": false,
                "postgres_changes": subscriptions
            ]
        ])
    }

    static func heartbeat(ref: String) throws -> String {
        try frame(event: "heartbeat", ref: ref, joinRef: nil, topic: "phoenix", payload: [:])
    }

    static func refresh(token: String, ref: String, joinRef: String) throws -> String {
        try frame(event: "access_token", ref: ref, joinRef: joinRef, payload: ["access_token": token])
    }

    private static func frame(event: String, ref: String, joinRef: String?, topic: String = topic, payload: [String: Any]) throws -> String {
        let value: [String: Any] = ["topic": topic, "event": event, "ref": ref, "join_ref": joinRef as Any? ?? NSNull(), "payload": payload]
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    static func incoming(_ text: String, joinRef: String, heartbeatRef: String?) -> PalRealtimeEvent {
        guard let bytes = text.data(using: .utf8), bytes.count <= 512 * 1024,
              let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let event = frame["event"] as? String,
              let payload = frame["payload"] as? [String: Any] else { return .ignored }
        if frame["topic"] as? String == "phoenix" {
            return event == "phx_reply" && heartbeatRef != nil && frame["ref"] as? String == heartbeatRef && payload["status"] as? String == "ok" ? .heartbeat : .ignored
        }
        guard frame["topic"] as? String == topic else { return .ignored }
        switch event {
        case "phx_close", "phx_error": return .reconnect
        case "phx_reply":
            if payload["status"] as? String == "error" { return .reconnect }
            return frame["ref"] as? String == joinRef && payload["status"] as? String == "ok" ? .joined : .ignored
        case "system":
            if payload["status"] as? String == "error" { return .reconnect }
            return payload["extension"] as? String == "postgres_changes" && payload["status"] as? String == "ok" ? .ready : .ignored
        case "postgres_changes":
            guard let data = payload["data"] as? [String: Any], data["schema"] as? String == "public", let table = data["table"] as? String, tables.contains(table),
                  let kind = data["type"] as? String, ["INSERT", "UPDATE", "DELETE"].contains(kind) else { return .ignored }
            let current = ((data["record"] as? [String: Any])?["group_id"] as? String).flatMap(UUID.init(uuidString:))
            let previous = ((data["old_record"] as? [String: Any])?["group_id"] as? String).flatMap(UUID.init(uuidString:))
            // A delete can omit group_id; a move can affect two groups. Refetch authorized groups.
            if let current, let previous, current != previous { return .change(nil) }
            return .change(current ?? previous)
        default: return .ignored
        }
    }

    /// Only a bounded text INSERT from the authenticated, subscribed messages table
    /// may precede its API snapshot. Storage metadata and URLs never enter this path.
    static func insertedMessage(_ text: String, groupIDs: Set<UUID>) -> ChatMessage? {
        guard let bytes = text.data(using: .utf8), bytes.count <= 512 * 1024,
              let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              frame["topic"] as? String == topic, frame["event"] as? String == "postgres_changes",
              let payload = frame["payload"] as? [String: Any], let data = payload["data"] as? [String: Any],
              data["schema"] as? String == "public", data["table"] as? String == "messages", data["type"] as? String == "INSERT",
              let record = data["record"] as? [String: Any],
              let id = (record["id"] as? String).flatMap(UUID.init(uuidString:)),
              let groupID = (record["group_id"] as? String).flatMap(UUID.init(uuidString:)), groupIDs.contains(groupID),
              let role = record["role"] as? String, ["user", "pal"].contains(role),
              let body = record["body"] as? String, body.utf16.count <= 4000, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let createdAt = record["created_at"] as? String, createdAt.utf8.count <= 64, PalDate.date(createdAt) != nil else { return nil }
        if let source = record["source_key"] as? String, source.hasPrefix("weekly:") || source.hasPrefix("pal:weekly:") { return nil }
        var fields: [String: Any] = ["id": id.uuidString, "group_id": groupID.uuidString, "role": role, "body": body, "created_at": createdAt]
        for key in ["sender_id", "client_id", "reply_to_id"] {
            if let raw = record[key], !(raw is NSNull) {
                guard let value = (raw as? String).flatMap(UUID.init(uuidString:)) else { return nil }
                fields[key] = value.uuidString
            }
        }
        if role == "user", fields["sender_id"] == nil { return nil }
        if let emotion = record["emotion"] as? String, emotion.utf8.count <= 40 { fields["emotion"] = emotion }
        if let mentions = record["mentions"] as? [[String: Any]], mentions.count <= 20 {
            fields["mentions"] = mentions.compactMap { mention -> [String: String]? in
                if mention["type"] as? String == "pal" { return ["type": "pal"] }
                guard mention["type"] as? String == "user", let userID = (mention["user_id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
                return ["type": "user", "user_id": userID.uuidString]
            }
        }
        if let card = record["card"] as? [String: Any], let type = card["type"] as? String,
           ["plan", "rsvp", "options", "choice", "availability", "question"].contains(type),
           let entity = (card["entity_id"] as? String).flatMap(UUID.init(uuidString:)) {
            var clean: [String: Any] = ["type": type, "entity_id": entity.uuidString]
            if let source = (card["source_id"] as? String).flatMap(UUID.init(uuidString:)) { clean["source_id"] = source.uuidString }
            if let question = card["question"] as? String, question.utf16.count <= 200 { clean["question"] = question }
            if let suggestions = card["suggestions"] as? [String], (2...4).contains(suggestions.count), suggestions.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 60 }) { clean["suggestions"] = suggestions }
            fields["cards"] = [clean]
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return try? JSONDecoder().decode(ChatMessage.self, from: normalized)
    }

    static func isNewMessage(_ message: ChatMessage, among existing: [ChatMessage]) -> Bool {
        !existing.contains { $0.id == message.id || (message.clientID != nil && $0.clientID == message.clientID) }
    }

    static func reconnectDelay(failures: Int) -> Double { min(30, pow(2, Double(max(0, min(failures, 6))))) }
}

// Cancellation handlers run outside the main actor. URLSession task cancellation is thread-safe.
private final class RealtimeSocketLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var cancelled = false
    init(session: URLSession) { self.session = session }
    func attach(_ socket: URLSessionWebSocketTask) {
        lock.lock()
        self.socket = socket
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { socket.cancel() }
    }
    func detach() { lock.lock(); socket = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let current = socket; lock.unlock()
        current?.cancel()
        session.invalidateAndCancel()
    }
}
