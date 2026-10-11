import Foundation

indirect enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

enum PalDate {
    static func date(_ string: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: string) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: string)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

struct ChatGroup: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let inviteCode: String
    var unreadCount: Int?
    var lastMessage: GroupLastMessage?
    enum CodingKeys: String, CodingKey { case id, name; case inviteCode = "invite_code", unreadCount = "unread_count", lastMessage = "last_message" }
}
struct GroupLastMessage: Codable, Hashable {
    var id: UUID?
    var body: String
    var createdAt: String
    var role: String?
    enum CodingKeys: String, CodingKey { case id,body,role; case createdAt = "created_at" }
}
struct MessageCard: Codable, Hashable, Identifiable {
    var type: String
    var entityID: UUID
    var sourceID: UUID?
    var id: String { type + entityID.uuidString }
    enum CodingKeys: String, CodingKey { case type; case entityID = "entity_id", sourceID = "source_id" }
}
struct ChatMessage: Decodable, Identifiable {
    let id: UUID
    let groupID: UUID
    let senderID: UUID?
    let role: String
    let body: String
    let createdAt: String
    let replyToID: UUID?
    let clientID: UUID?
    let cards: [MessageCard]
    enum CodingKeys: String, CodingKey {
        case id, role, body, cards
        case groupID = "group_id", senderID = "sender_id", createdAt = "created_at", replyToID = "reply_to_id", clientID = "client_id"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        groupID = try c.decode(UUID.self, forKey: .groupID)
        senderID = try c.decodeIfPresent(UUID.self, forKey: .senderID)
        role = try c.decode(String.self, forKey: .role)
        body = try c.decode(String.self, forKey: .body)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        replyToID = try c.decodeIfPresent(UUID.self, forKey: .replyToID)
        clientID = try c.decodeIfPresent(UUID.self, forKey: .clientID)
        cards = try c.decodeIfPresent([MessageCard].self, forKey: .cards) ?? []
    }
}
struct GroupMember: Decodable, Identifiable {
    var userID: UUID
    var displayName: String?
    var avatarURL: String?
    var lastReadAt: String?
    var lastReadMessageID: UUID?
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey { case userID = "user_id", displayName = "display_name", avatarURL = "avatar_url", lastReadAt = "last_read_at", lastReadMessageID = "last_read_message_id" }
}
struct PlaceCandidate: Decodable, Identifiable {
    var id: String?
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var providerID: String?
    var provider: String?
    enum CodingKeys: String, CodingKey { case id,name,address,latitude,longitude,provider; case providerID = "provider_id" }
}
struct PlaceContributor: Decodable {
    var userID: UUID
    var sourceID: UUID?
    enum CodingKeys: String, CodingKey { case userID = "user_id", sourceID = "source_id" }
}

struct GroupPlace: Decodable, Identifiable {
    var id: UUID
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var provider: String
    var providerID: String?
    var status: String
    var candidates: [PlaceCandidate]
    var website: String?
    var bookingURL: String?
    var contributors: [PlaceContributor]?
    enum CodingKeys: String, CodingKey { case id,name,address,latitude,longitude,provider,status,candidates,website,contributors; case providerID = "provider_id", bookingURL = "booking_url" }
}
struct GroupSource: Decodable, Identifiable {
    var id: UUID
    var url: String?
    var title: String?
    var status: String
    var placeID: UUID?
    var placeIDs: [UUID]?
    var candidates: [SourceCandidate]?
    var contributors: [PlaceContributor]?
    var metadata: [String: JSONValue]?
    var extraction: [String: JSONValue]?
    var lastError: String?
    enum CodingKeys: String, CodingKey { case id,url,title,status,candidates,contributors,metadata,extraction; case placeID = "place_id", placeIDs = "place_ids", lastError = "last_error" }
    var thumbnailURL: URL? {
        var values = metadata ?? [:]
        if case .object(let extra) = extraction?["metadata"] { values.merge(extra) { existing, _ in existing } }
        for key in ["thumbnailUrl", "thumbnail_url", "thumbnail", "image", "cover"] {
            var raw: String?
            if case .string(let value) = values[key] { raw = value }
            else if case .object(let object) = values[key], case .string(let value) = object["url"] { raw = value }
            if let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { return url }
        }
        return nil
    }
}
struct SourceCandidate: Decodable {
    var name: String
    var city: String?
    var address: String?
    var dishes: [String]?
    var prices: [String]?
    var evidence: [String]?
    var confidence: JSONValue?
    var options: [PlaceCandidate]?
}
struct PollOption: Decodable, Identifiable {
    var id: String
    var label: String
    var startsAt: String?
    var endsAt: String?
    var placeID: UUID?
    enum CodingKeys: String, CodingKey { case id,label; case startsAt = "starts_at", endsAt = "ends_at", placeID = "place_id" }
}
struct PollVote: Decodable {
    var userID: UUID
    var optionID: String
    enum CodingKeys: String, CodingKey { case userID = "user_id", optionID = "option_id" }
}
struct GroupPoll: Decodable, Identifiable {
    var id: UUID
    var kind: String
    var question: String
    var options: [PollOption]
    var status: String
    var deadlineAt: String?
    var votes: [PollVote]
    enum CodingKeys: String, CodingKey { case id,kind,question,options,status,votes; case deadlineAt = "deadline_at" }
}
struct PlanAttendee: Decodable {
    var userID: UUID
    var status: String
    enum CodingKeys: String, CodingKey { case userID = "user_id", status }
}
struct GroupPlan: Decodable, Identifiable {
    var id: UUID
    var title: String
    var startsAt: String?
    var endsAt: String?
    var placeID: UUID?
    var status: String
    var notes: String?
    var bookingStatus: String?
    var bookingReference: String?
    var attendees: [PlanAttendee]
    enum CodingKeys: String, CodingKey { case id,title,status,notes,attendees; case startsAt = "starts_at", endsAt = "ends_at", placeID = "place_id", bookingStatus = "booking_status", bookingReference = "booking_reference" }
}
struct GroupMemory: Decodable, Identifiable {
    var id: UUID
    var userID: UUID?
    var kind: String
    var key: String
    var value: String
    var body: String?
    var expiresAt: String?
    enum CodingKeys: String, CodingKey { case id,kind,key,value,body; case userID = "user_id", expiresAt = "expires_at" }
}
struct GroupReminder: Decodable, Identifiable {
    var id: UUID
    var body: String
    var dueAt: String
    var timezone: String
    var status: String
    var planID: UUID?
    var pollID: UUID?
    var targetUserIDs: [UUID]?
    enum CodingKeys: String, CodingKey { case id,body,timezone,status; case dueAt = "due_at", planID = "plan_id", pollID = "poll_id", targetUserIDs = "target_user_ids" }
}
struct MessageReaction: Decodable {
    var messageID: UUID
    var userID: UUID?
    var emoji: String
    enum CodingKeys: String, CodingKey { case messageID = "message_id", userID = "user_id", emoji }
}
struct GroupSettings: Decodable {
    var timezone: String?
    var proactiveSuggestions: Bool?
    var agentPaused: Bool?
    var name: String?
    enum CodingKeys: String, CodingKey { case timezone,name; case proactiveSuggestions = "proactive_suggestions", agentPaused = "agent_paused" }
}
struct GroupState: Decodable {
    var members: [GroupMember]
    var places: [GroupPlace]
    var sources: [GroupSource]
    var polls: [GroupPoll]
    var plans: [GroupPlan]
    var memories: [GroupMemory]
    var reminders: [GroupReminder]
    var reactions: [MessageReaction]
    var settings: GroupSettings?
    static var empty: GroupState { GroupState(members: [], places: [], sources: [], polls: [], plans: [], memories: [], reminders: [], reactions: [], settings: nil) }
}
struct PalProfile: Decodable {
    struct Preferences: Decodable { var enabled: Bool? }
    var userID: UUID?
    var displayName: String?
    var avatarURL: String?
    var notificationPreferences: Preferences?
    enum CodingKeys: String, CodingKey { case userID = "user_id", displayName = "display_name", avatarURL = "avatar_url", notificationPreferences = "notification_preferences" }
}
struct CalendarStatus: Decodable {
    var connected: Bool
    var syncError: String?
    enum CodingKeys: String, CodingKey { case connected; case syncError = "sync_error" }
}

struct OutgoingMessage: Codable, Identifiable {
    var groupID: UUID
    var userID: UUID
    var clientID: UUID
    var body: String
    var replyToID: UUID?
    var failed: Bool
    var id: UUID { clientID }
}
