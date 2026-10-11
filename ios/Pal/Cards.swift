import SwiftUI

struct AvatarView: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.18))
            Text(name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.secondary)
            if let url, let address = URL(string: url), ["https", "http"].contains(address.scheme ?? "") {
                AsyncImage(url: address) { image in image.resizable().scaledToFill() } placeholder: { EmptyView() }
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct PalCardView: View {
    let group: ChatGroup
    let card: MessageCard
    @EnvironmentObject private var store: PalStore
    private var state: GroupState { store.states[group.id] ?? .empty }
    var body: some View {
        Group {
            switch card.type {
            case "place":
                if let place = state.places.first(where: { $0.id == card.entityID }) {
                    NavigationLink { PlaceDetailView(group: group, place: place) } label: { VStack(alignment: .leading, spacing: 6) { cardLabel("mappin.and.ellipse", title: place.name, subtitle: place.status == "resolved" ? (place.address ?? "Saved place") : "Choose the correct place"); ContributorLine(group: group, contributors: place.contributors) } }
                } else if let source = state.sources.first(where: { $0.id == card.entityID || $0.id == card.sourceID }) {
                    SourceCardView(group: group, source: source)
                } else { cardLabel("mappin", title: "Place", subtitle: "Loading details…") }
            case "choice", "availability": PollCardView(group: group, pollID: card.entityID)
            case "plan":
                if let plan = state.plans.first(where: { $0.id == card.entityID }) {
                    NavigationLink { PlanDetailView(group: group, plan: plan) } label: {
                        cardLabel("calendar", title: plan.title, subtitle: [plan.startsAt.flatMap(PalDate.date).map { $0.formatted(date: .abbreviated, time: .shortened) }, plan.status.capitalized].compactMap { $0 }.joined(separator: " · "))
                    }
                } else { cardLabel("calendar", title: "Plan", subtitle: "Loading details…") }
            case "reminder":
                if let reminder = state.reminders.first(where: { $0.id == card.entityID }) {
                    NavigationLink { ReminderEditor(group: group, reminder: reminder) } label: {
                        cardLabel("bell", title: reminder.body, subtitle: (PalDate.date(reminder.dueAt)?.formatted(date: .abbreviated, time: .shortened) ?? reminder.dueAt) + " · " + reminder.status.capitalized)
                    }
                } else { cardLabel("bell", title: "Reminder", subtitle: "Loading details…") }
            default: EmptyView()
            }
        }.buttonStyle(.plain).padding(14).frame(maxWidth: 300, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5))
    }
    private func cardLabel(_ icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct PollCardView: View {
    let group: ChatGroup
    let pollID: UUID
    @EnvironmentObject private var store: PalStore
    @State private var busy = false
    private var poll: GroupPoll? { store.states[group.id]?.polls.first { $0.id == pollID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let poll {
                Label(poll.kind == "time" ? "Availability" : "Group choice", systemImage: poll.kind == "time" ? "calendar" : "checklist").font(.caption).foregroundStyle(.secondary)
                Text(poll.question).font(.headline)
                ForEach(poll.options) { option in
                    let votes = poll.votes.filter { $0.optionID == option.id }.count
                    let ownVotes = poll.votes.filter { $0.userID == store.userID }
                    let selected = ownVotes.contains { $0.optionID == option.id }
                    let locked = busy || poll.status != "open" || (selected && (poll.kind != "time" || ownVotes.count <= 1))
                    Button { vote(option, poll: poll, selected: selected) } label: {
                        HStack {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(option.label)
                                if let time = option.startsAt.flatMap(PalDate.date) { Text(time, format: .dateTime.month().day().hour().minute()).font(.caption) }
                            }
                            Spacer()
                            Text("\(votes)").font(.caption)
                        }
                    }.frame(minHeight: 44)
                        .accessibilityLabel(Text("\(option.label), \(votes) votes"))
                        .accessibilityValue(selected ? "Selected" : "Not selected")
                        .disabled(locked)
                }
                Text(poll.status == "open" ? (poll.kind == "time" ? "Select every time that works for you." : "Choose one option.") : "Voting closed").font(.caption).foregroundStyle(.secondary)
                if let deadline = poll.deadlineAt.flatMap(PalDate.date) { Text("Closes \(deadline.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            } else { ProgressView("Loading vote…") }
        }.task { if poll == nil { do { try await store.loadState(group) } catch { store.error = error.localizedDescription } } }
    }
    private func vote(_ option: PollOption, poll: GroupPoll, selected: Bool) {
        busy = true
        Task {
            defer { busy = false }
            var selections = poll.kind == "time" ? poll.votes.filter { $0.userID == store.userID }.map(\.optionID) : []
            if selected { selections.removeAll { $0 == option.id } } else { selections.append(option.id) }
            do { try await store.mutate(group, action: "poll.vote", data: ["id": .string(poll.id.uuidString), "option_ids": .array(selections.map(JSONValue.string))]) }
            catch { store.error = error.localizedDescription }
        }
    }

}

struct SourceCardView: View {
    let group: ChatGroup
    let source: GroupSource
    @EnvironmentObject private var store: PalStore
    @State private var busy = false
    private var saved: [GroupPlace] { (store.states[group.id]?.places ?? []).filter { source.placeIDs?.contains($0.id) == true || source.placeID == $0.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(source.title ?? "Shared place", systemImage: "link").font(.headline)
            ContributorLine(group: group, contributors: source.contributors)
            if let thumbnail = source.thumbnailURL {
                AsyncImage(url: thumbnail) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: Text("Preview unavailable").font(.caption).foregroundStyle(.secondary)
                    default: ProgressView()
                    }
                }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            }
            if let url = source.url.flatMap({ URL(string: $0) }), ["http", "https"].contains(url.scheme ?? "") {
                Link("Open " + (url.host ?? "source"), destination: url).font(.subheadline).frame(minHeight: 44, alignment: .leading)
            }
            if source.status == "failed" { Text(source.lastError ?? "Couldn’t inspect this video. Open the source or find the place manually.").font(.footnote).foregroundStyle(.secondary) }
            if ["pending", "resolving"].contains(source.status) { ProgressView("Finding places…") }
            ForEach(saved) { place in NavigationLink { PlaceDetailView(group: group, place: place) } label: { Label(place.name, systemImage: "mappin.circle").font(.subheadline) } }
            ForEach(Array((source.candidates ?? []).enumerated()), id: \.offset) { _, candidate in
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.name).font(.subheadline.weight(.semibold))
                    if let city = candidate.city { Text(city).font(.caption).foregroundStyle(.secondary) }
                    if let dishes = candidate.dishes, !dishes.isEmpty { Text("From the video: " + dishes.joined(separator: ", ")).font(.caption) }
                    if let prices = candidate.prices, !prices.isEmpty { Text("Video prices: " + prices.joined(separator: ", ")).font(.caption) }
                    if let evidence = candidate.evidence, !evidence.isEmpty { Text(evidence.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                    ForEach(Array((candidate.options ?? []).enumerated()), id: \.offset) { _, option in
                        Button { save(option) } label: { VStack(alignment: .leading) { Text("Save " + option.name); if let address = option.address { Text(address).font(.caption).foregroundStyle(.secondary) } } }.frame(minHeight: 44).disabled(busy || option.providerID == nil || option.latitude == nil || option.longitude == nil)
                    }
                }
            }
            if !["pending", "resolving"].contains(source.status) { NavigationLink("Find or correct a place") { PlaceSearchView(group: group, sourceID: source.id) } }
        }
    }
    private func save(_ option: PlaceCandidate) {
        guard let providerID = option.providerID, let latitude = option.latitude, let longitude = option.longitude else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await store.mutate(group, action: "place.save", data: ["source_id": .string(source.id.uuidString), "name": .string(option.name), "address": .string(option.address ?? ""), "latitude": .number(latitude), "longitude": .number(longitude), "provider": .string(option.provider ?? "apple"), "provider_id": .string(providerID)]) }
            catch { store.error = error.localizedDescription }
        }
    }
}

struct ContributorLine: View {
    let group: ChatGroup
    let contributors: [PlaceContributor]?
    @EnvironmentObject private var store: PalStore
    private var names: [String] {
        let ids = Set((contributors ?? []).map(\.userID))
        return (store.states[group.id]?.members ?? []).filter { ids.contains($0.userID) }.map { $0.displayName ?? "Member" }.sorted()
    }
    var body: some View {
        if !names.isEmpty { Text("Shared by " + names.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }
}
