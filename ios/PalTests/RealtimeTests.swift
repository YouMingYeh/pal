import XCTest
import Network
@testable import Pal

final class RealtimeTests: XCTestCase {
    func testAuthenticatedJoinScopesEveryTableToEachDistinctGroup() throws {
        let a = UUID(), b = UUID()
        let join = try object(PalRealtimeProtocol.join(token: "unit-test-auth", ref: "join-1", groupIDs: [a, b, a]))
        XCTAssertEqual(join["event"] as? String, "phx_join")
        XCTAssertEqual(join["topic"] as? String, PalRealtimeProtocol.topic)
        XCTAssertEqual(join["ref"] as? String, "join-1")
        XCTAssertEqual(join["join_ref"] as? String, "join-1")
        let payload = try XCTUnwrap(join["payload"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "unit-test-auth")
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        let subscriptions = try XCTUnwrap(config["postgres_changes"] as? [[String: String]])
        XCTAssertEqual(subscriptions.count, PalRealtimeProtocol.tables.count * 2)
        XCTAssertFalse(PalRealtimeProtocol.tables.contains("agent_jobs"))
        for groupID in [a, b] {
            let groupSubscriptions = subscriptions.filter { $0["filter"] == "group_id=eq.\(groupID.uuidString.lowercased())" }
            XCTAssertEqual(Set(groupSubscriptions.compactMap { $0["table"] }), Set(PalRealtimeProtocol.tables))
            XCTAssertTrue(groupSubscriptions.allSatisfy { $0["event"] == "*" && $0["schema"] == "public" })
        }
    }

    func testEndpointNeverRetainsBearerQueryAndRejectsUnsafeTransport() throws {
        let endpoint = try PalRealtimeProtocol.endpoint(url: XCTUnwrap(URL(string: "https://example.supabase.co?access_token=discard-this#discard")), key: "sb_publishable_unit-test")
        let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/realtime/v1/websocket")
        XCTAssertNil(components.fragment)
        XCTAssertEqual(Set(components.queryItems?.map(\.name) ?? []), ["apikey", "vsn"])
        XCTAssertFalse(endpoint.absoluteString.contains("discard-this"))
        XCTAssertThrowsError(try PalRealtimeProtocol.endpoint(url: XCTUnwrap(URL(string: "http://example.com")), key: "public"))
        XCTAssertThrowsError(try PalRealtimeProtocol.endpoint(url: XCTUnwrap(URL(string: "https://example.com")), key: "sb_secret_unit-test"))
    }

    func testHeartbeatAndRefreshHaveCorrectTopicReferenceAndAuthentication() throws {
        let heartbeat = try object(PalRealtimeProtocol.heartbeat(ref: "beat-2"))
        XCTAssertEqual(heartbeat["topic"] as? String, "phoenix")
        XCTAssertEqual(heartbeat["event"] as? String, "heartbeat")
        XCTAssertTrue(heartbeat["join_ref"] is NSNull)
        XCTAssertEqual((heartbeat["payload"] as? [String: Any])?.count, 0)
        let refresh = try object(PalRealtimeProtocol.refresh(token: "unit-test-refreshed", ref: "refresh-3", joinRef: "join-1"))
        XCTAssertEqual(refresh["event"] as? String, "access_token")
        XCTAssertEqual(refresh["join_ref"] as? String, "join-1")
        XCTAssertEqual((refresh["payload"] as? [String: String])?["access_token"], "unit-test-refreshed")
        let reply = try frame(topic: "phoenix", event: "phx_reply", ref: "beat-2", payload: ["status": "ok"])
        XCTAssertEqual(PalRealtimeProtocol.incoming(reply, joinRef: "join-1", heartbeatRef: "beat-2"), .heartbeat)
        XCTAssertEqual(PalRealtimeProtocol.incoming(reply, joinRef: "join-1", heartbeatRef: "other"), .ignored)
    }

    func testChangesExtractOnlyGroupUUIDAndMissingDeleteOrGroupMoveRefetchBroadly() throws {
        let group = UUID()
        for table in PalRealtimeProtocol.tables {
            for kind in ["INSERT", "UPDATE", "DELETE"] {
                let data: [String: Any] = ["schema": "public", "table": table, "type": kind,
                    "record": kind == "DELETE" ? [:] : ["group_id": group.uuidString, "body": "discarded", "storage_path": "discarded"],
                    "old_record": ["group_id": group.uuidString]]
                XCTAssertEqual(try parseChange(data), .change(group))
            }
        }
        XCTAssertEqual(try parseChange(["schema": "public", "table": "messages", "type": "DELETE", "old_record": ["id": UUID().uuidString]]), .change(nil))
        XCTAssertEqual(try parseChange(["schema": "public", "table": "places", "type": "UPDATE", "record": ["group_id": "invalid"]]), .change(nil))
        XCTAssertEqual(try parseChange(["schema": "public", "table": "plans", "type": "UPDATE", "record": ["group_id": group.uuidString], "old_record": ["group_id": UUID().uuidString]]), .change(nil))
        XCTAssertEqual(try parseChange(["schema": "private", "table": "messages", "type": "INSERT"]), .ignored)
        XCTAssertEqual(try parseChange(["schema": "public", "table": "profiles", "type": "INSERT"]), .ignored)
    }

    func testMalformedEventsAreIgnoredAndJoinFailureReconnectsWithBoundedDelay() throws {
        for text in ["not-json", "[]", "{}", "{\"event\":\"postgres_changes\",\"payload\":null}"] {
            XCTAssertEqual(PalRealtimeProtocol.incoming(text, joinRef: "join-1", heartbeatRef: nil), .ignored)
        }
        let joined = try frame(event: "phx_reply", ref: "join-1", payload: ["status": "ok"])
        XCTAssertEqual(PalRealtimeProtocol.incoming(joined, joinRef: "join-1", heartbeatRef: nil), .joined)
        XCTAssertEqual(PalRealtimeProtocol.incoming(joined, joinRef: "different", heartbeatRef: nil), .ignored)
        let denied = try frame(event: "phx_reply", ref: "join-1", payload: ["status": "error"])
        XCTAssertEqual(PalRealtimeProtocol.incoming(denied, joinRef: "join-1", heartbeatRef: nil), .reconnect)
        XCTAssertEqual(PalRealtimeProtocol.reconnectDelay(failures: 0), 1)
        XCTAssertEqual(PalRealtimeProtocol.reconnectDelay(failures: 2), 4)
        XCTAssertEqual(PalRealtimeProtocol.reconnectDelay(failures: 100), 30)
    }

    func testChannelJoinAndPostgresReadinessAreDistinctProtocolEvents() throws {
        let joined = try frame(event: "phx_reply", ref: "join-1", payload: ["status": "ok"])
        let ready = try frame(event: "system", payload: ["status": "ok", "extension": "postgres_changes"])
        let unrelated = try frame(event: "system", payload: ["status": "ok", "extension": "other"])
        XCTAssertEqual(PalRealtimeProtocol.incoming(joined, joinRef: "join-1", heartbeatRef: nil), .joined)
        XCTAssertEqual(PalRealtimeProtocol.incoming(ready, joinRef: "join-1", heartbeatRef: nil), .ready)
        XCTAssertEqual(PalRealtimeProtocol.incoming(unrelated, joinRef: "join-1", heartbeatRef: nil), .ignored)
    }

    @MainActor func testCancellationClosesRealSocketWhileHandshakeIsSuspended() async throws {
        // A local TCP transport deliberately holds the HTTP upgrade. No Supabase data or credentials.
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Local TCP listener ready")
        let requested = expectation(description: "URLSession sent a real WebSocket upgrade")
        let closed = expectation(description: "Cancellation closed the actual TCP connection")
        let finished = expectation(description: "Cancelled realtime run finished")
        let connections = HeldConnections()
        let queue = DispatchQueue(label: "PalRealtimeTransportTest")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connections.add(connection)
            connection.start(queue: queue)
            HeldConnections.readUpgrade(connection, onUpgrade: { requested.fulfill() }, onClosed: { closed.fulfill() })
        }
        listener.start(queue: queue)
        defer { listener.cancel(); connections.cancel() }
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)"))
        let realtime = PalRealtime()
        let run = Task { @MainActor in
            await realtime.run(url: base, key: "sb_publishable_unit-test", groupIDs: [UUID()], token: { "unit-test-auth" }, onChange: { _ in XCTFail("Unjoined transport cannot invalidate a group") })
            finished.fulfill()
        }
        defer { run.cancel() }
        await fulfillment(of: [requested], timeout: 3)
        let socket = try XCTUnwrap(realtime.activeSocket)
        XCTAssertTrue(realtime.isRunning)
        await realtime.run(url: base, key: "sb_publishable_unit-test", groupIDs: [UUID()], token: { XCTFail("A second run must not open a second connection"); return "unit-test-auth" }, onChange: { _ in })
        XCTAssertTrue(realtime.activeSocket === socket)
        run.cancel()
        await fulfillment(of: [finished, closed], timeout: 3)
        XCTAssertFalse(realtime.isRunning)
        XCTAssertFalse(realtime.isHeartbeatRunning)
        XCTAssertNil(realtime.activeSocket)
        // URLSessionWebSocketTask.state can lag behind cancellation. Peer EOF proves
        // transport teardown rather than assuming its task wrapper updates synchronously.
    }

    private func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
    private func frame(topic: String = PalRealtimeProtocol.topic, event: String, ref: String? = nil, payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["topic": topic, "event": event, "ref": ref as Any? ?? NSNull(), "payload": payload])
        return String(decoding: data, as: UTF8.self)
    }
    private func parseChange(_ data: [String: Any]) throws -> PalRealtimeEvent {
        PalRealtimeProtocol.incoming(try frame(event: "postgres_changes", payload: ["data": data]), joinRef: "join-1", heartbeatRef: nil)
    }
    private final class HeldConnections: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [NWConnection] = []
        func add(_ item: NWConnection) { lock.lock(); items.append(item); lock.unlock() }
        func cancel() { lock.lock(); let current = items; items = []; lock.unlock(); current.forEach { $0.cancel() } }
        static func readUpgrade(_ connection: NWConnection, accumulated: Data = Data(), onUpgrade: @escaping () -> Void, onClosed: @escaping () -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
                var bytes = accumulated
                if let data { bytes.append(data) }
                guard bytes.count <= 16384 else { return }
                if let headers = String(data: bytes, encoding: .utf8), headers.contains("\r\n\r\n") {
                    if headers.lowercased().contains("upgrade: websocket") {
                        onUpgrade()
                        readUntilClosed(connection, onClosed: onClosed)
                    }
                } else if !complete, error == nil {
                    readUpgrade(connection, accumulated: bytes, onUpgrade: onUpgrade, onClosed: onClosed)
                }
            }
        }
        static func readUntilClosed(_ connection: NWConnection, onClosed: @escaping () -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, complete, error in
                if complete || error != nil { onClosed() }
                else { readUntilClosed(connection, onClosed: onClosed) }
            }
        }
    }
}
