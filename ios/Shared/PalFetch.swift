import Foundation

/// Coalesces overlapping reads without tying their lifetime to one screen's task.
@MainActor final class PalFetchPool {
    private struct Flight { let id: UUID; let task: Task<Data, Error> }
    private var flights: [String: Flight] = [:]
    private var generation = UUID()
    private var revisions: [String: Int] = [:]

    func value(for key: String, operation: @escaping @MainActor () async throws -> Data) async throws -> Data {
        let expectedGeneration = generation
        let revision = revisions[key, default: 0]
        let flight: Flight
        if let current = flights[key] { flight = current }
        else {
            flight = Flight(id: UUID(), task: Task { try await operation() })
            flights[key] = flight
        }
        defer { if flights[key]?.id == flight.id { flights[key] = nil } }
        let value = try await flight.task.value
        try Task.checkCancellation()
        guard generation == expectedGeneration, revisions[key, default: 0] == revision else { throw CancellationError() }
        return value
    }

    func clear() {
        generation = UUID()
        flights.values.forEach { $0.task.cancel() }
        flights.removeAll()
        revisions.removeAll()
    }

    func invalidate(where matches: (String) -> Bool) {
        for key in Array(flights.keys) where matches(key) {
            // Let existing reads finish; their snapshots are obsolete after the successful write.
            revisions[key, default: 0] += 1
            flights[key] = nil
        }
    }
}

struct PalFetchState: Equatable {
    private var requests = 0
    var isLoading: Bool { requests > 0 }
    var hasLoaded = false
    var issue: String?

    mutating func begin() { requests += 1; issue = nil }
    mutating func finish() { requests = max(0, requests - 1); hasLoaded = true; issue = nil }
    mutating func fail(_ error: Error) {
        requests = max(0, requests - 1)
        if !PalCancellation.isCancellation(error) { issue = error.localizedDescription }
    }
}

struct PalReadReceipt: Decodable {
    let lastReadAt: String?
    enum CodingKeys: String, CodingKey { case lastReadAt = "last_read_at" }

    func apply(to member: inout GroupMember, messageID: UUID, targetCreatedAt: String?) {
        guard let lastReadAt, let confirmed = PalDate.date(lastReadAt),
              confirmed >= (member.lastReadAt.flatMap(PalDate.date) ?? .distantPast) else { return }
        member.lastReadAt = lastReadAt
        // The server stores the target message's time and can reject an older read marker.
        if targetCreatedAt.flatMap(PalDate.date) == confirmed { member.lastReadMessageID = messageID }
    }
}
