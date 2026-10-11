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

    func testTextInsertFastPathKeepsToneAndCardsButDiscardsRawStorageAndURLs() throws {
        let group = UUID(), entity = UUID(), member = UUID()
        var record = textRecord(group: group)
        record["role"] = "pal"; record["sender_id"] = NSNull(); record["emotion"] = "heureux"
        record["card"] = ["type": "plan", "entity_id": entity.uuidString, "url": "https://untrusted.example", "storage_path": "private/path"]
        record["mentions"] = [["type": "user", "user_id": member.uuidString, "avatar_url": "https://untrusted.example"]]
        record["attachments"] = [["id": UUID().uuidString, "url": "https://untrusted.example"]]
        record["reply"] = ["id": UUID().uuidString, "body": "Unverified quote"]
        record["storage_path"] = "private/path"
        let message = try XCTUnwrap(PalRealtimeProtocol.insertedMessage(try insert(record), groupIDs: [group]))
        XCTAssertEqual(message.emotion, "heureux")
        XCTAssertEqual(message.cards, [MessageCard(type: "plan", entityID: entity)])
        XCTAssertEqual(message.mentions, [MessageMention(type: "user", userID: member)])
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertNil(message.reply)
    }

    func testTextInsertFastPathRejectsOtherGroupsMalformedRecordsAndHiddenMessages() throws {
        let group = UUID(), valid = textRecord(group: group)
        XCTAssertNotNil(PalRealtimeProtocol.insertedMessage(try insert(valid), groupIDs: [group]))
        XCTAssertNil(PalRealtimeProtocol.insertedMessage(try insert(valid), groupIDs: [UUID()]))
        for (key, value) in [("id", "invalid"), ("sender_id", "invalid"), ("client_id", "invalid"), ("reply_to_id", "invalid"),
                             ("role", "system"), ("body", "  \n"), ("body", String(repeating: "x", count: 4001)), ("created_at", "not a date"),
                             ("source_key", "weekly:old"), ("source_key", "pal:weekly:old")] {
            var record = valid; record[key] = value
            XCTAssertNil(PalRealtimeProtocol.insertedMessage(try insert(record), groupIDs: [group]), key)
        }
        var missingSender = valid; missingSender["sender_id"] = NSNull()
        XCTAssertNil(PalRealtimeProtocol.insertedMessage(try insert(missingSender), groupIDs: [group]))
        for data: [String: Any] in [["schema": "private", "table": "messages", "type": "INSERT", "record": valid],
                                   ["schema": "public", "table": "messages", "type": "UPDATE", "record": valid],
                                   ["schema": "public", "table": "message_attachments", "type": "INSERT", "record": valid]] {
            XCTAssertNil(PalRealtimeProtocol.insertedMessage(try frame(event: "postgres_changes", payload: ["data": data]), groupIDs: [group]))
        }
        XCTAssertNil(PalRealtimeProtocol.insertedMessage("not-json", groupIDs: [group]))
    }

    func testInsertDoesNotReplaceAnEnrichedCachedMessageOrDuplicateItsClientID() throws {
        let group = UUID(), client = UUID()
        var record = textRecord(group: group); record["client_id"] = client.uuidString
        var fields = record
        fields["attachments"] = [["id": UUID().uuidString, "kind": "image", "url": "https://example.com/signed-image", "mime_type": "image/jpeg", "byte_size": 100]]
        fields["reply"] = ["id": UUID().uuidString, "role": "pal", "body": "Confirmed quote"]
        let enriched = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields))
        var cache = PalMessageCache(); cache.acknowledge(enriched)
        let raw = try XCTUnwrap(PalRealtimeProtocol.insertedMessage(try insert(record), groupIDs: [group]))
        if PalRealtimeProtocol.isNewMessage(raw, among: cache.messages[group] ?? []) { cache.acknowledge(raw) }
        XCTAssertEqual(cache.messages[group], [enriched], "The authenticated HTTP attachment and reply must survive a duplicate CDC event.")
        record["id"] = UUID().uuidString
        let duplicateClient = try XCTUnwrap(PalRealtimeProtocol.insertedMessage(try insert(record), groupIDs: [group]))
        XCTAssertFalse(PalRealtimeProtocol.isNewMessage(duplicateClient, among: cache.messages[group] ?? []))
        record["id"] = UUID().uuidString; record["client_id"] = UUID().uuidString
        let next = try XCTUnwrap(PalRealtimeProtocol.insertedMessage(try insert(record), groupIDs: [group]))
        XCTAssertTrue(PalRealtimeProtocol.isNewMessage(next, among: cache.messages[group] ?? []))
        let olderRead = cache.beginFetch(groupID: group)
        cache.acknowledge(next)
        XCTAssertTrue(cache.acceptSnapshot([enriched], groupID: group, sequence: olderRead).contains(next), "An older HTTP snapshot cannot remove a newly received bubble.")
    }

    @MainActor func testRealtimeRejectsAnEarlierReadButAllowsAFreshSnapshotToDeleteItsMessage() async throws {
        let group = UUID(), pool = PalFetchPool(), key = "/api/groups/\(group)/messages"
        let started = expectation(description: "Pre-INSERT read is suspended")
        var release: CheckedContinuation<Data, Never>?
        let earlierRead = Task { @MainActor in
            try await pool.value(for: key) {
                await withCheckedContinuation { release = $0; started.fulfill() }
            }
        }
        defer { earlierRead.cancel(); pool.clear() }
        await fulfillment(of: [started], timeout: 3)
        var cache = PalMessageCache()
        let message = try XCTUnwrap(PalRealtimeProtocol.insertedMessage(try insert(textRecord(group: group)), groupIDs: [group]))
        pool.invalidate { $0 == key }
        cache.acknowledge(message, protectUntilSnapshot: false)
        XCTAssertEqual(cache.messages[group]?.map(\.id), [message.id])
        try XCTUnwrap(release).resume(returning: Data("[]".utf8))
        do { _ = try await earlierRead.value; XCTFail("A pre-INSERT snapshot must never reach the message cache.") }
        catch { XCTAssertTrue(PalCancellation.isCancellation(error)) }
        XCTAssertEqual(cache.messages[group]?.map(\.id), [message.id])
        let fresh = try await pool.value(for: key) { Data("[]".utf8) }
        let snapshot = try JSONDecoder().decode([ChatMessage].self, from: fresh)
        let sequence = cache.beginFetch(groupID: group)
        XCTAssertTrue(cache.acceptSnapshot(snapshot, groupID: group, sequence: sequence).isEmpty, "An authoritative post-INSERT snapshot must remove a message deleted or reset before that read.")
    }

    @MainActor func testRealSocketKeepsReceivingDuringSlowRefreshAndCancelsItsWorker() async throws {
        let queue = DispatchQueue(label: "PalRealtimeWebSocketTest")
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { _, _ in NWProtocolWebSocket.Response(status: .accept, subprotocol: nil) }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: parameters, on: .any)
        let listening = expectation(description: "WebSocket listener ready")
        let joined = expectation(description: "Actual authenticated Phoenix join received")
        let refreshStarted = expectation(description: "Slow authoritative refresh started")
        let received = expectation(description: "Both INSERTs received before refresh finishes"); received.expectedFulfillmentCount = 2
        let workerCancelled = expectation(description: "Owned refresh worker cancelled")
        let finished = expectation(description: "Realtime run cancelled")
        let peer = WebSocketPeer()
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.newConnectionHandler = { connection in peer.accept(connection, queue: queue, onJoin: { joined.fulfill() }) }
        listener.start(queue: queue)
        defer { listener.cancel(); peer.cancel() }
        await fulfillment(of: [listening], timeout: 3)
        let port = try XCTUnwrap(listener.port), group = UUID()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port.rawValue)"))
        let realtime = PalRealtime()
        var refreshCalls = 0
        var receivedIDs = Set<UUID>()
        let run = Task { @MainActor in
            await realtime.run(url: url, key: "sb_publishable_unit-test", groupIDs: [group], token: { "unit-test-auth" }, onMessage: { message in
                XCTAssertEqual(refreshCalls, 1, "Receiving must not wait for the active HTTP refresh.")
                receivedIDs.insert(message.id); received.fulfill()
            }, onChange: { _ in
                refreshCalls += 1; refreshStarted.fulfill()
                do { try await Task.sleep(for: .seconds(30)); XCTFail("The slow worker should be cancelled") }
                catch { workerCancelled.fulfill() }
            })
            finished.fulfill()
        }
        defer { run.cancel() }
        await fulfillment(of: [joined, refreshStarted], timeout: 3)
        peer.send(try insert(textRecord(group: group)))
        peer.send(try insert(textRecord(group: group)))
        peer.send(try insert(textRecord(group: UUID()))) // Even valid text must belong to the subscription.
        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(receivedIDs.count, 2)
        XCTAssertEqual(refreshCalls, 1, "Burst invalidations queue one follow-up instead of starting concurrent refreshes.")
        run.cancel()
        await fulfillment(of: [workerCancelled, finished], timeout: 3)
        XCTAssertFalse(realtime.isRunning)
        XCTAssertFalse(realtime.isHeartbeatRunning)
        XCTAssertNil(realtime.activeSocket)
    }

    @MainActor func testParallelStateRefreshCannotRestoreRemovedMembershipOrRegressPreview() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Authentication fixtures belong only to the simulator.")
        #else
        let original = SessionKeychain.load(), account = UUID(), groupID = UUID(), newestID = UUID()
        try SessionKeychain.save(StoredSession(AuthSession(accessToken: "realtime-store-fixture", refreshToken: "unused", expiresIn: 3600, expiresAt: nil, user: .init(id: account, email: nil))))
        defer { SessionKeychain.clear(); if let original { try? SessionKeychain.save(original) } }
        let stateStarted = expectation(description: "Authorized state read is held in flight")
        let groupJSON: [String: Any] = ["id": groupID.uuidString, "name": "Realtime fixture", "last_message": ["id": newestID.uuidString, "body": "Newest preview", "role": "user", "created_at": "2026-10-11T21:00:00Z"]]
        RealtimeStoreURLProtocol.prepare(group: groupJSON, message: textRecord(group: groupID), onState: { stateStarted.fulfill() })
        URLProtocol.registerClass(RealtimeStoreURLProtocol.self)
        defer { RealtimeStoreURLProtocol.releaseState(); URLProtocol.unregisterClass(RealtimeStoreURLProtocol.self) }
        let store = PalStore()
        defer { store.signOut() }
        try await store.loadGroups()
        let group = try XCTUnwrap(store.groups.first)
        _ = try await store.send("Earlier post acknowledgement", to: group, clientID: UUID())
        XCTAssertEqual(store.groups.first?.lastMessage?.id, newestID, "An older arriving INSERT or send acknowledgement must not replace a newer chat preview.")
        let stateRead = Task { @MainActor in try await store.loadState(group) }
        defer { stateRead.cancel() }
        await fulfillment(of: [stateStarted], timeout: 3)
        RealtimeStoreURLProtocol.removeMembership()
        try await store.loadGroups()
        XCTAssertTrue(store.groups.isEmpty)
        RealtimeStoreURLProtocol.releaseState()
        do { try await stateRead.value; XCTFail("A state snapshot cannot restore membership removed by the parallel inbox refresh.") }
        catch { XCTAssertTrue(PalCancellation.isCancellation(error)) }
        XCTAssertNil(store.states[groupID])
        #endif
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
    private func textRecord(group: UUID) -> [String: Any] {
        ["id": UUID().uuidString, "group_id": group.uuidString, "sender_id": UUID().uuidString, "role": "user", "body": "Dinner at seven?", "created_at": "2026-10-11T20:00:00.123456+00:00"]
    }
    private func insert(_ record: [String: Any]) throws -> String {
        try frame(event: "postgres_changes", payload: ["data": ["schema": "public", "table": "messages", "type": "INSERT", "record": record]])
    }
    private final class WebSocketPeer: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: NWConnection?
        func accept(_ connection: NWConnection, queue: DispatchQueue, onJoin: @escaping () -> Void) {
            lock.lock(); self.connection = connection; lock.unlock()
            connection.start(queue: queue)
            connection.receiveMessage { [weak self] bytes, _, _, _ in
                guard let bytes, let join = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      join["event"] as? String == "phx_join", let ref = join["ref"] as? String,
                      let reply = try? JSONSerialization.data(withJSONObject: ["topic": PalRealtimeProtocol.topic, "event": "phx_reply", "ref": ref, "payload": ["status": "ok"]]) else { return }
                self?.send(String(decoding: reply, as: UTF8.self)); onJoin()
            }
        }
        func send(_ string: String) {
            lock.lock(); let current = connection; lock.unlock()
            let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            current?.send(content: Data(string.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
        func cancel() { lock.lock(); let current = connection; connection = nil; lock.unlock(); current?.cancel() }
    }
    private final class RealtimeStoreURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var inbox = Data(), sent = Data()
        private static var held: RealtimeStoreURLProtocol?
        private static var onState: (() -> Void)?
        static func prepare(group: [String: Any], message: [String: Any], onState: @escaping () -> Void) {
            lock.lock(); defer { lock.unlock() }
            inbox = try! JSONSerialization.data(withJSONObject: ["groups": [group]])
            sent = try! JSONSerialization.data(withJSONObject: ["message": message])
            held = nil; self.onState = onState
        }
        static func removeMembership() { lock.lock(); inbox = Data("{\"groups\":[]}".utf8); lock.unlock() }
        static func releaseState() {
            lock.lock(); let pending = held; held = nil; lock.unlock()
            pending?.respond(Data("{\"members\":[],\"places\":[],\"sources\":[],\"polls\":[],\"plans\":[],\"memories\":[],\"reminders\":[],\"reactions\":[],\"locations\":[]}".utf8))
        }
        override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "Authorization") == "Bearer realtime-store-fixture" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            if request.url?.path.hasSuffix("/state") == true {
                Self.held = self; let notify = Self.onState; Self.onState = nil; Self.lock.unlock(); notify?(); return
            }
            let bytes = request.url?.path == "/api/groups" ? Self.inbox : request.httpMethod == "POST" ? Self.sent : Data("{\"messages\":[]}".utf8)
            Self.lock.unlock(); respond(bytes)
        }
        private func respond(_ data: Data) {
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.lock.lock(); if Self.held === self { Self.held = nil }; Self.lock.unlock() }
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
