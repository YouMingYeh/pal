import Foundation

struct PalMessageCache {
    private(set) var messages: [UUID: [ChatMessage]] = [:]
    private var awaitingSnapshot: [UUID: [ChatMessage]] = [:]
    private var fetchSequence = 0
    private var firstSequence: [UUID: Int] = [:]
    private var latestSequence: [UUID: Int] = [:]
    private var acceptedSequence: [UUID: Int] = [:]

    mutating func beginFetch(groupID: UUID) -> Int {
        fetchSequence += 1
        if firstSequence[groupID] == nil { firstSequence[groupID] = fetchSequence }
        latestSequence[groupID] = fetchSequence
        return fetchSequence
    }

    @discardableResult
    mutating func acceptSnapshot(_ snapshot: [ChatMessage], groupID: UUID, sequence: Int) -> [ChatMessage] {
        guard let first = firstSequence[groupID], let latest = latestSequence[groupID],
              sequence >= first, sequence <= latest,
              sequence > (acceptedSequence[groupID] ?? 0) else { return messages[groupID] ?? [] }
        acceptedSequence[groupID] = sequence
        let remote = snapshot.filter { $0.groupID == groupID }
        // Only seeing the acknowledged ID/client ID in a GET ends its protection.
        let pending = (awaitingSnapshot[groupID] ?? []).filter { acknowledged in
            !remote.contains { Self.sameMessage($0, acknowledged) }
        }
        awaitingSnapshot[groupID] = pending
        let recent = Array(Self.sorted(Self.upsert([], adding: remote)).suffix(200))
        let merged = Self.sorted(Self.upsert(recent, adding: pending))
        messages[groupID] = merged
        return merged
    }

    func latestAcknowledgement(groupID: UUID) -> ChatMessage? {
        Self.sorted(awaitingSnapshot[groupID] ?? []).last
    }

    func needsRefresh(groupID: UUID, latestMessageID: UUID?) -> Bool {
        guard let cached = messages[groupID] else { return true }
        return cached.last?.id != latestMessageID
    }

    mutating func acknowledge(_ message: ChatMessage, protectUntilSnapshot: Bool = true) {
        let groupID = message.groupID
        if protectUntilSnapshot { awaitingSnapshot[groupID] = Self.upsert(awaitingSnapshot[groupID] ?? [], adding: [message]) }
        messages[groupID] = Self.sorted(Self.upsert(messages[groupID] ?? [], adding: [message]))
    }

    mutating func prune(groupIDs: Set<UUID>) {
        messages = messages.filter { groupIDs.contains($0.key) }
        awaitingSnapshot = awaitingSnapshot.filter { groupIDs.contains($0.key) }
        firstSequence = firstSequence.filter { groupIDs.contains($0.key) }
        latestSequence = latestSequence.filter { groupIDs.contains($0.key) }
        acceptedSequence = acceptedSequence.filter { groupIDs.contains($0.key) }
    }

    mutating func clear() {
        messages.removeAll()
        awaitingSnapshot.removeAll()
        firstSequence.removeAll()
        latestSequence.removeAll()
        acceptedSequence.removeAll()
        // Do not reuse sequence numbers after logout; in-flight callbacks are stale.
    }

    private static func sameMessage(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        a.id == b.id || (a.clientID != nil && a.clientID == b.clientID)
    }

    private static func upsert(_ existing: [ChatMessage], adding incoming: [ChatMessage]) -> [ChatMessage] {
        var result = existing
        for message in incoming {
            result.removeAll { sameMessage($0, message) }
            result.append(message)
        }
        return result
    }

    private static func sorted(_ values: [ChatMessage]) -> [ChatMessage] {
        values.map { ($0, PalDate.date($0.createdAt) ?? .distantPast) }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.id.uuidString < $1.0.id.uuidString
            }.map { $0.0 }
    }
}
