import Foundation
import UIKit

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
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()
    static func date(_ string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? whole.parse(string))
    }
    static func iso(_ date: Date) -> String { whole.format(date) }
}

struct ChatGroup: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let inviteCode: String
    var unreadCount: Int?
    var lastMessage: GroupLastMessage?
    var avatarURL: String?
    let isDirect: Bool
    enum CodingKeys: String, CodingKey { case id, name; case inviteCode = "invite_code", unreadCount = "unread_count", lastMessage = "last_message", avatarURL = "avatar_url", isDirect = "is_direct" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        inviteCode = try c.decodeIfPresent(String.self, forKey: .inviteCode) ?? ""
        unreadCount = try c.decodeIfPresent(Int.self, forKey: .unreadCount)
        lastMessage = try c.decodeIfPresent(GroupLastMessage.self, forKey: .lastMessage)
        avatarURL = try c.decodeIfPresent(String.self, forKey: .avatarURL)
        isDirect = try c.decodeIfPresent(Bool.self, forKey: .isDirect) ?? false
    }
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
    var question: String? = nil
    var suggestions: [String]? = nil
    var id: String { type + entityID.uuidString + (type == "question" ? (question ?? "") : "") }
    var suggestedAnswers: [String] {
        guard type == "question", let suggestions, (2...4).contains(suggestions.count) else { return [] }
        let answers = suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard answers.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 60 }), Set(answers.map { $0.lowercased() }).count == answers.count else { return [] }
        return answers
    }
    func questionText(for groupID: UUID) -> String? {
        guard type == "question", entityID == groupID, let question, !suggestedAnswers.isEmpty else { return nil }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf16.count <= 200 ? text : nil
    }
    enum CodingKeys: String, CodingKey { case type, question, suggestions; case entityID = "entity_id", sourceID = "source_id" }
}
struct MessageMention: Codable, Hashable {
    var type: String
    var userID: UUID? = nil
    enum CodingKeys: String, CodingKey { case type; case userID = "user_id" }
}
struct MessageReply: Decodable, Equatable {
    var id: UUID
    var senderID: UUID?
    var role: String
    var body: String
    enum CodingKeys: String, CodingKey { case id, role, body; case senderID = "sender_id" }
}

struct ChatMessage: Decodable, Identifiable, Equatable {
    let id: UUID
    let groupID: UUID
    let senderID: UUID?
    let role: String
    let body: String
    let createdAt: String
    let replyToID: UUID?
    let clientID: UUID?
    let cards: [MessageCard]
    let attachments: [ChatAttachment]
    let emotion: String?
    let mentions: [MessageMention]
    let reply: MessageReply?
    var timelineID: UUID { clientID ?? id }
    enum CodingKeys: String, CodingKey {
        case id, role, body, cards, attachments, emotion, mentions, reply
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
        attachments = try c.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        emotion = try c.decodeIfPresent(String.self, forKey: .emotion)
        mentions = try c.decodeIfPresent([MessageMention].self, forKey: .mentions) ?? []
        reply = try c.decodeIfPresent(MessageReply.self, forKey: .reply)
    }
    /// Keep sender labels and delivery times on the edges of a short message run.
    func follows(_ previous: ChatMessage, calendar: Calendar = .current) -> Bool {
        guard role != "system", role == previous.role, senderID == previous.senderID,
              let currentDate = PalDate.date(createdAt), let previousDate = PalDate.date(previous.createdAt) else { return false }
        let interval = currentDate.timeIntervalSince(previousDate)
        return calendar.isDate(currentDate, inSameDayAs: previousDate) && (0...180).contains(interval)
    }
    /// Rich cards render their persisted records; older card types retain a text fallback.
    func plainBody(in state: GroupState) -> String? {
        var sections: [String] = []
        if let text = displayedBody(in: state), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(text) }
        for card in cards {
            var text: String?
            switch card.type {
            case "plan", "rsvp", "options", "choice", "availability": continue
            case "question": if card.questionText(for: groupID) != nil { continue }
            case "reminder":
                if let reminder = state.reminders.first(where: { $0.id == card.entityID }) {
                    text = [reminder.body, PalDate.date(reminder.dueAt)?.formatted(date: .abbreviated, time: .shortened), reminder.status == "cancelled" ? "Cancelled" : nil].compactMap { $0 }.joined(separator: " · ")
                }
            case "place":
                if let place = state.places.first(where: { $0.id == card.entityID }) { text = [place.name, place.address].compactMap { $0 }.joined(separator: "\n") }
                else if let source = state.sources.first(where: { $0.id == card.entityID || $0.id == card.sourceID }) {
                    let places = state.places.filter { (source.placeIDs ?? []).contains($0.id) }
                    if !places.isEmpty { text = places.map { [$0.name, $0.address].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n") }
                    else if source.status == "failed" { text = "I couldn't read this link. " + (source.url ?? "") }
                    else if source.status == "pending" { text = "Taking a look at this link. " + (source.url ?? "") }
                    else { text = source.title ?? source.url }
                }
            default: break
            }
            if let text, !text.isEmpty, !sections.contains(text), !sections.contains(where: { $0.contains(text) }) { sections.append(text) }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
    func displayedBody(in state: GroupState) -> String? {
        let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty && ["Photo", "Voice message"].contains(value) { return nil }
        if ["https", "http"].contains(URL(string: value)?.scheme ?? "") { return body }
        for card in cards {
            var title: String?
            switch card.type {
            case "plan", "rsvp": title = state.plans.first { $0.id == card.entityID }?.title
            case "question": title = card.questionText(for: groupID)
            case "reminder":
                title = state.reminders.first { $0.id == card.entityID }?.body
                if let title, value == "Reminder: " + title { return nil }
            case "options", "choice", "availability": title = state.polls.first { $0.id == card.entityID }?.question
            case "place":
                title = state.places.first { $0.id == card.entityID }?.name
                if let source = state.sources.first(where: { $0.id == card.entityID || $0.id == card.sourceID }) {
                    title = title ?? source.title
                    if ["Finding places...", "Finding places…"].contains(value) { return nil }
                }
            default: break
            }
            if let title, value == title.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        }
        return body
    }
}

enum PalText {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    static func linked(_ body: String, markdown: Bool = false, mentions: [MessageMention] = [], members: [GroupMember] = []) -> AttributedString {
        var result = markdown ? ((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)) : AttributedString(body)
        let names = mentions.compactMap { mention in mention.type == "pal" ? "Pal" : members.first { $0.userID == mention.userID }?.displayName }
        for name in names {
            let pattern = "@" + NSRegularExpression.escapedPattern(for: name) + "(?=$|[\\s.,!?，。！？])"
            let visible = String(result.characters)
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: visible, range: NSRange(visible.startIndex..., in: visible)) {
                if let textRange = Range(match.range, in: visible), let range = Range(textRange, in: result) { result[range].inlinePresentationIntent = .stronglyEmphasized }
            }
        }
        let visible = String(result.characters)
        guard let detector = linkDetector else { return result }
        for match in detector.matches(in: visible, range: NSRange(visible.startIndex..., in: visible)) {
            guard let url = match.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  let stringRange = Range(match.range, in: visible), let range = Range(stringRange, in: result) else { continue }
            result[range].link = url
            result[range].underlineStyle = .single
        }
        return result
    }
}
enum PalMentions {
    private static let expression = try! NSRegularExpression(pattern: "(?:^|\\s)@([^@\\n]*)$")
    private static func range(in text: String) -> Range<String.Index>? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range(at: 1), in: text) }
    }
    static func query(in text: String) -> String? {
        guard let range = range(in: text) else { return nil }
        let query = String(text[range])
        return query.hasSuffix(" ") ? nil : query
    }
    static func inserting(name: String, into text: String) -> String {
        guard let range = range(in: text) else { return text }
        return text.replacingCharacters(in: range, with: name + " ")
    }
    static func candidates(in members: [GroupMember], query: String, excluding userID: UUID?) -> [GroupMember] {
        members.filter { $0.userID != userID && (query.isEmpty || ($0.displayName ?? "Member").localizedCaseInsensitiveContains(query)) }
    }
    static func retained(_ selected: [MessageMention: String], in text: String) -> [MessageMention] {
        selected.filter { _, name in
            let pattern = "@" + NSRegularExpression.escapedPattern(for: name) + "(?=$|[\\s.,!?，。！？])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }.map(\.key).sorted { ($0.userID?.uuidString ?? "pal") < ($1.userID?.uuidString ?? "pal") }
    }
}

struct GroupMember: Decodable, Identifiable, Equatable {
    var userID: UUID
    var displayName: String?
    var avatarURL: String?
    var lastReadAt: String?
    var lastReadMessageID: UUID?
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey { case userID = "user_id", displayName = "display_name", avatarURL = "avatar_url", lastReadAt = "last_read_at", lastReadMessageID = "last_read_message_id" }
}
struct PlaceCandidate: Decodable, Identifiable, Equatable {
    var id: String?
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var providerID: String?
    var provider: String?
    enum CodingKeys: String, CodingKey { case id,name,address,latitude,longitude,provider; case providerID = "provider_id" }
}
struct PlaceContributor: Decodable, Equatable {
    var userID: UUID
    var sourceID: UUID?
    enum CodingKeys: String, CodingKey { case userID = "user_id", sourceID = "source_id" }
}

struct GroupPlace: Decodable, Identifiable, Equatable {
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
struct GroupSource: Decodable, Identifiable, Equatable {
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
struct SourceCandidate: Decodable, Equatable {
    var name: String
    var city: String?
    var address: String?
    var dishes: [String]?
    var prices: [String]?
    var evidence: [String]?
    var confidence: JSONValue?
    var options: [PlaceCandidate]?
}
struct PollOption: Decodable, Identifiable, Equatable {
    var id: String
    var label: String
    var startsAt: String?
    var endsAt: String?
    var placeID: UUID?
    enum CodingKeys: String, CodingKey { case id,label; case startsAt = "starts_at", endsAt = "ends_at", placeID = "place_id" }
}
struct PollVote: Decodable, Equatable {
    var userID: UUID
    var optionID: String
    enum CodingKeys: String, CodingKey { case userID = "user_id", optionID = "option_id" }
}
struct PollResponse: Decodable, Equatable {
    var userID: UUID
    var optionIDs: [String]
    enum CodingKeys: String, CodingKey { case userID = "user_id", optionIDs = "option_ids" }
}
struct GroupPoll: Decodable, Identifiable, Equatable {
    var id: UUID
    var kind: String
    var question: String
    var options: [PollOption]
    var status: String
    var deadlineAt: String?
    var votes: [PollVote]
    var responses: [PollResponse]?
    func canVote(now: Date = Date()) -> Bool {
        guard status == "open" else { return false }
        guard let deadlineAt else { return true }
        guard let deadline = PalDate.date(deadlineAt) else { return false }
        return deadline > now
    }
    func noneWork(for userID: UUID?) -> Bool {
        guard kind == "time", let userID else { return false }
        return responses?.contains { $0.userID == userID && $0.optionIDs.isEmpty } == true
    }
    func availability(for userID: UUID) -> String? {
        guard kind == "time" else { return nil }
        let response = responses?.first { $0.userID == userID }
        let selections = response?.optionIDs ?? votes.filter { $0.userID == userID }.map(\.optionID)
        if response != nil && selections.isEmpty { return "None of these times" }
        let labels = options.filter { selections.contains($0.id) }.map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
    enum CodingKeys: String, CodingKey { case id,kind,question,options,status,votes,responses; case deadlineAt = "deadline_at" }
}
struct PlanAttendee: Decodable, Equatable {
    var userID: UUID
    var status: String
    enum CodingKeys: String, CodingKey { case userID = "user_id", status }
}
struct GroupPlan: Decodable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var startsAt: String?
    var endsAt: String?
    var placeID: UUID?
    var status: String
    var notes: String?
    var bookingStatus: String?
    var bookingReference: String?
    var version: Int?
    var attendees: [PlanAttendee]
    func response(for userID: UUID?) -> String? { attendees.first { $0.userID == userID }?.status }
    func canRSVP(now: Date = Date()) -> Bool { status == "confirmed" && startsAt.flatMap(PalDate.date).map { $0 > now } == true }
    func attendanceSummary(memberCount: Int) -> String {
        let going = attendees.filter { $0.status == "going" }.count
        let maybe = attendees.filter { $0.status == "maybe" }.count
        let declined = attendees.filter { $0.status == "declined" }.count
        let unanswered = max(0, memberCount - Set(attendees.map(\.userID)).count)
        return "\(going) going" + (maybe > 0 ? " · \(maybe) maybe" : "") + (declined > 0 ? " · \(declined) not going" : "") + (unanswered > 0 ? " · \(unanswered) awaiting reply" : "")
    }
    enum CodingKeys: String, CodingKey { case id,title,status,notes,attendees,version; case startsAt = "starts_at", endsAt = "ends_at", placeID = "place_id", bookingStatus = "booking_status", bookingReference = "booking_reference" }
}
struct GroupMemory: Decodable, Identifiable, Equatable {
    var id: UUID
    var userID: UUID?
    var kind: String
    var key: String
    var value: String
    var body: String?
    var expiresAt: String?
    func isCurrentAvailability(for memberID: UUID, now: Date = Date()) -> Bool {
        kind == "availability" && userID == memberID && expiresAt.flatMap(PalDate.date).map { $0 > now } == true
    }
    enum CodingKeys: String, CodingKey { case id,kind,key,value,body; case userID = "user_id", expiresAt = "expires_at" }
}
struct GroupReminder: Decodable, Identifiable, Equatable {
    var id: UUID
    var body: String
    var dueAt: String
    var timezone: String
    var status: String
    var planID: UUID?
    var pollID: UUID?
    var targetUserIDs: [UUID]?
    var requesterID: UUID?
    var kind: String?
    func canEdit(userID: UUID?) -> Bool { userID != nil && requesterID == userID && (kind ?? "reminder") == "reminder" && status == "scheduled" }
    enum CodingKeys: String, CodingKey { case id,body,timezone,status,kind; case dueAt = "due_at", planID = "plan_id", pollID = "poll_id", targetUserIDs = "target_user_ids", requesterID = "requester_id" }
}
struct MessageReaction: Decodable, Equatable {
    var messageID: UUID
    var userID: UUID?
    var emoji: String
    enum CodingKeys: String, CodingKey { case messageID = "message_id", userID = "user_id", emoji }
}
struct GroupSettings: Decodable, Equatable {
    var timezone: String?
    var proactiveSuggestions: Bool?
    var agentPaused: Bool?
    var name: String?
    enum CodingKeys: String, CodingKey { case timezone,name; case proactiveSuggestions = "proactive_suggestions", agentPaused = "agent_paused" }
}
struct GroupState: Decodable, Equatable {
    var members: [GroupMember]
    var places: [GroupPlace]
    var sources: [GroupSource]
    var polls: [GroupPoll]
    var plans: [GroupPlan]
    var memories: [GroupMemory]
    var reminders: [GroupReminder]
    var reactions: [MessageReaction]
    var settings: GroupSettings?
    var palActivity: PalWorkActivity? = nil
    var locations: [GroupMemberLocation] = []
    enum CodingKeys: String, CodingKey {
        case members, places, sources, polls, plans, memories, reminders, reactions, settings, locations
        case palActivity = "pal_activity"
    }
    static var empty: GroupState { GroupState(members: [], places: [], sources: [], polls: [], plans: [], memories: [], reminders: [], reactions: [], settings: nil) }
}

struct GroupMemberLocation: Decodable, Equatable, Identifiable {
    let userID: UUID
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let updatedAt: String
    let expiresAt: String
    var id: UUID { userID }
    enum CodingKeys: String, CodingKey {
        case latitude, longitude, accuracy
        case userID = "user_id", updatedAt = "updated_at", expiresAt = "expires_at"
    }
    func isFresh(at now: Date = Date()) -> Bool {
        guard let expiry = PalDate.date(expiresAt), let updated = PalDate.date(updatedAt) else { return false }
        return expiry > now && updated <= now.addingTimeInterval(30) && now.timeIntervalSince(updated) <= 3600
            && latitude.isFinite && (-90...90).contains(latitude) && longitude.isFinite && (-180...180).contains(longitude)
            && accuracy.isFinite && (0...10_000).contains(accuracy)
    }
}

extension GroupState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = try c.decode([GroupMember].self, forKey: .members)
        places = try c.decode([GroupPlace].self, forKey: .places)
        sources = try c.decode([GroupSource].self, forKey: .sources)
        polls = try c.decode([GroupPoll].self, forKey: .polls)
        plans = try c.decode([GroupPlan].self, forKey: .plans)
        memories = try c.decode([GroupMemory].self, forKey: .memories)
        reminders = try c.decode([GroupReminder].self, forKey: .reminders)
        reactions = try c.decode([MessageReaction].self, forKey: .reactions)
        settings = try c.decodeIfPresent(GroupSettings.self, forKey: .settings)
        palActivity = try c.decodeIfPresent(PalWorkActivity.self, forKey: .palActivity)
        locations = try c.decodeIfPresent([GroupMemberLocation].self, forKey: .locations) ?? []
    }
}

/// Every room shows only a bounded explicit reply phase, never queued or decision work.
struct PalWorkActivity: Decodable, Equatable {
    var activity: String
    var jobID: UUID?
    var status: String?
    var expiresAt: String?
    enum CodingKeys: String, CodingKey { case activity, status; case jobID = "job_id", expiresAt = "expires_at" }
    func isThinking(at now: Date = Date()) -> Bool {
        let replying = activity == "typing" && status == "running"
        return replying && jobID != nil && (expiresAt.flatMap(PalDate.date).map { $0 > now } ?? false)
    }
}

/// An optimistic status ends at the first authoritative state read after its POST, or at a bounded deadline.
struct PalTypingHint {
    let clientID: UUID
    let expiresAt: Date
    private(set) var postedAfterSequence: Int?
    init(clientID: UUID, now: Date = Date()) { self.clientID = clientID; expiresAt = now.addingTimeInterval(120) }
    mutating func posted(after sequence: Int) { postedAfterSequence = sequence }
    func acceptsState(sequence: Int) -> Bool { postedAfterSequence.map { sequence > $0 } ?? false }
    func isVisible(at now: Date = Date()) -> Bool { now < expiresAt }
}

struct PalProfile: Decodable, Equatable {
    struct Preferences: Decodable, Equatable { var enabled: Bool? }
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

struct OutgoingMessage: Codable, Identifiable, Equatable {
    var groupID: UUID
    var userID: UUID
    var clientID: UUID
    var body: String
    var replyToID: UUID?
    var failed: Bool
    var attachment: DraftAttachment?
    var createdAt: String? = nil
    var mentions: [MessageMention]? = nil
    var id: UUID { clientID }
}

enum ChatTimelineItem: Identifiable {
    case message(ChatMessage), outgoing(OutgoingMessage)
    var id: UUID { switch self { case .message(let message): return message.timelineID; case .outgoing(let item): return item.clientID } }
    var createdAt: String { switch self { case .message(let message): return message.createdAt; case .outgoing(let item): return item.createdAt ?? "" } }
    var message: ChatMessage? { if case .message(let value) = self { return value }; return nil }
}

/// Navigation cancels URLSession with URLError rather than Swift CancellationError.
enum PalCancellation {
    static func isCancellation(_ error: Error, taskCancelled: Bool = Task<Never, Never>.isCancelled) -> Bool {
        if taskCancelled || error is CancellationError { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }
}

struct MemberSummary: Decodable {
    struct Source: Decodable, Identifiable { let id: UUID; let body: String }
    let summary: String?
    let sources: [Source]
    let availability: [GroupMemory]
    let preferences: [GroupMemory]
    static func key(groupID: UUID, userID: UUID) -> String { groupID.uuidString + "/" + userID.uuidString }
}
