import Foundation

// Phoenix JSON protocol v1: https://supabase.com/docs/guides/realtime/protocol
// Events are invalidations only. The authorized API remains the source of chat data.
@MainActor final class PalRealtime {
    private(set) var isRunning = false
    private(set) var activeSocket: URLSessionWebSocketTask?
    private(set) var isHeartbeatRunning = false

    func run(url: URL, key: String, groupIDs: [UUID],
             token: @escaping () async throws -> String,
             onReady: (() async -> Void)? = nil,
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
                    let connection = Connection(socket: socket, token: accessToken)
                    activeSocket = socket
                    lifetime.attach(socket)
                    socket.resume()
                    try await RealtimeWebSocket.send(PalRealtimeProtocol.join(token: accessToken, ref: connection.joinRef, groupIDs: groupIDs), on: socket)
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { @MainActor in
                            try await self.receive(connection, onReady: onReady, onChange: onChange)
                        }
                        group.addTask { @MainActor in
                            try await self.heartbeat(connection, token: token)
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

    private func receive(_ connection: Connection, onReady: (() async -> Void)?, onChange: @escaping (UUID?) async -> Void) async throws {
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
                    await onChange(nil) // Catch changes missed while disconnected or backgrounded.
                }
            case .heartbeat:
                connection.heartbeatRef = nil
            case .ready:
                if connection.joined, !connection.ready {
                    connection.ready = true
                    await onChange(nil) // CDC readiness can follow channel join after a separate delay.
                    await onReady?()
                }
            case .change(let groupID):
                if connection.joined { await onChange(groupID) }
            case .reconnect: throw URLError(.networkConnectionLost)
            case .ignored: break
            }
        }
        throw CancellationError()
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
        let joinRef = UUID().uuidString
        var token: String
        var joined = false
        var ready = false
        var heartbeatRef: String?
        init(socket: URLSessionWebSocketTask, token: String) { self.socket = socket; self.token = token }
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
    static let tables = ["messages", "message_attachments", "message_reactions", "sources", "places", "place_contributors", "polls", "poll_responses", "plans", "plan_rsvps", "reminders", "member_memories"]

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
