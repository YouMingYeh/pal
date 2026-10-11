import SwiftUI

struct AvatarView: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 36
    var imageCache: PalImageCache = .shared
    var body: some View {
        ZStack {
            Circle().fill(Color(uiColor: .tertiarySystemFill))
            Text(name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.secondary)
            if let url, let address = URL(string: url), ["https", "http"].contains(address.scheme ?? "") {
                PalCachedAvatarImage(url: address, cache: imageCache)
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
            case "options", "choice", "availability": PollCardView(group: group, pollID: card.entityID)
            case "plan", "rsvp": RSVPCardView(group: group, planID: card.entityID)
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
            Image(systemName: icon).foregroundStyle(PalTheme.ink).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct CardRecordStatusView: View {
    let group: ChatGroup
    let title: String
    @EnvironmentObject private var store: PalStore
    var body: some View {
        let fetch = store.stateFetch[group.id] ?? PalFetchState()
        VStack(alignment: .leading, spacing: 8) {
            if let issue = fetch.issue {
                Text("Couldn’t load \(title.lowercased()).").font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { try? await store.loadState(group) } }.disabled(fetch.isLoading).accessibilityHint(issue)
            } else if fetch.hasLoaded && !fetch.isLoading {
                Text("\(title) is no longer available.").font(.subheadline).foregroundStyle(.secondary)
            } else { ProgressView("Loading \(title.lowercased())…") }
        }.frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }
}

struct PollCardView: View {
    let group: ChatGroup
    let pollID: UUID
    @EnvironmentObject private var store: PalStore
    @State private var busy = false
    @State private var issue: String?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var poll: GroupPoll? { state.polls.first { $0.id == pollID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let poll {
                Label(poll.kind == "time" ? "Availability" : "Ideas for the group", systemImage: poll.kind == "time" ? "calendar" : "sparkles").font(.caption).foregroundStyle(.secondary)
                Text(poll.question).font(.headline)
                if poll.canVote() { Text(poll.kind == "time" ? "Choose times" : "Pick a favorite").font(.subheadline.weight(.semibold)).foregroundStyle(.primary) }
                ForEach(poll.options) { option in
                    let votes = poll.votes.filter { $0.optionID == option.id }.count
                    let selected = poll.votes.contains { $0.userID == store.userID && $0.optionID == option.id }
                    VStack(alignment: .leading, spacing: 4) {
                        Button { vote(option, poll: poll, selected: selected) } label: {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.label).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                                    if let time = option.startsAt.flatMap(PalDate.date) {
                                        Text(time, format: .dateTime.weekday(.abbreviated).month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                    } else if let place = state.places.first(where: { $0.id == option.placeID }), let address = place.address {
                                        Text(address).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 4)
                                if votes > 0 { Text("\(votes)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            }.padding(10).frame(maxWidth: .infinity, minHeight: 50)
                                .background(selected ? PalTheme.accent.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                        }.foregroundStyle(selected ? PalTheme.accentText : PalTheme.ink)
                            .accessibilityLabel(Text("\(option.label), \(votes) selected"))
                            .accessibilityValue(selected ? "Selected" : "Not selected")
                            .disabled(busy || !poll.canVote())
                        if let place = state.places.first(where: { $0.id == option.placeID }) {
                            NavigationLink { PlaceDetailView(group: group, place: place) } label: {
                                Label("Place details", systemImage: "arrow.up.right").font(.caption)
                            }.frame(minHeight: 44).padding(.leading, 10)
                        }
                    }
                }
                if poll.kind == "time" {
                    let noneSelected = poll.noneWork(for: store.userID)
                    Button { submit([], poll: poll) } label: {
                        Label("None of these times", systemImage: noneSelected ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.foregroundStyle(noneSelected ? PalTheme.accentText : PalTheme.ink).accessibilityValue(noneSelected ? "Selected" : "Not selected").disabled(busy || !poll.canVote() || noneSelected)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Everyone’s schedule").font(.subheadline.weight(.semibold))
                        ForEach(state.members) { member in
                            let facts = Array(Set(state.memories.filter { $0.isCurrentAvailability(for: member.userID) }.map(\.value))).sorted()
                            NavigationLink { MemberDetailView(groupID: group.id, member: member) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                AvatarView(name: member.displayName ?? "Member", url: member.avatarURL, size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.displayName ?? "Member").font(.caption.weight(.semibold))
                                    if let availability = poll.availability(for: member.userID) { Text(availability).font(.caption).foregroundStyle(.secondary) }
                                    if !facts.isEmpty { Text("From chat: " + facts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                    if poll.availability(for: member.userID) == nil && facts.isEmpty { Text("Not shared yet").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).foregroundStyle(.primary)
                            }.buttonStyle(.plain).accessibilityHint("Member details")
                        }
                        let unknown = state.members.filter { member in
                            poll.availability(for: member.userID) == nil && !state.memories.contains { $0.isCurrentAvailability(for: member.userID) }
                        }.count
                        if unknown > 0 && poll.canVote() { Text("Waiting for \(unknown) \(unknown == 1 ? "person" : "people")").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Text(poll.canVote() ? "You can change your answer." : "Responses closed").font(.caption).foregroundStyle(.secondary)
                if let issue { Text(issue).font(.caption).foregroundStyle(PalTheme.error) }
            } else { CardRecordStatusView(group: group, title: "Options") }
        }.task { if poll == nil { try? await store.loadState(group) } }
    }
    private func vote(_ option: PollOption, poll: GroupPoll, selected: Bool) {
        var selections = poll.kind == "time" ? poll.votes.filter { $0.userID == store.userID }.map(\.optionID) : []
        if selected && poll.kind == "time" { selections.removeAll { $0 == option.id } } else { selections.append(option.id) }
        submit(selections, poll: poll)
    }
    private func submit(_ selections: [String], poll: GroupPoll) {
        guard poll.canVote(), !busy else { return }
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do { try await store.mutate(group, action: "poll.vote", data: ["id": .string(poll.id.uuidString), "option_ids": .array(selections.map(JSONValue.string))]) }
            catch { if !PalCancellation.isCancellation(error) { issue = "Couldn’t save your answer. Try again." } }
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
                }.frame(maxWidth: .infinity, maxHeight: 140).clipped().clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
            }
            if let url = source.url.flatMap({ URL(string: $0) }), ["http", "https"].contains(url.scheme ?? "") {
                Link("Open " + (url.host ?? "source"), destination: url).tint(PalTheme.accentText).font(.subheadline).frame(minHeight: 44, alignment: .leading)
            }
            if source.status == "failed" { Text(source.lastError ?? "Couldn’t inspect this video. Open the source or find the place manually.").font(.footnote).foregroundStyle(.secondary) }
            if ["pending", "resolving"].contains(source.status) { ProgressView("Finding places…") }
            ForEach(saved) { place in NavigationLink { PlaceDetailView(group: group, place: place) } label: { Label(place.name, systemImage: "mappin.circle").font(.subheadline) } }
            ForEach(Array((source.candidates ?? []).enumerated()), id: \.offset) { _, candidate in
                VStack(alignment: .leading, spacing: 6) {
                    if source.candidates?.count != 1 || candidate.name != source.title { Text(candidate.name).font(.subheadline.weight(.semibold)) }
                    if let city = candidate.city { Text(city).font(.caption).foregroundStyle(.secondary) }
                    if (candidate.dishes?.isEmpty == false) || (candidate.prices?.isEmpty == false) || (candidate.evidence?.isEmpty == false) {
                        DisclosureGroup("Video details") {
                    if let dishes = candidate.dishes, !dishes.isEmpty { Text("From the video: " + dishes.joined(separator: ", ")).font(.caption) }
                    if let prices = candidate.prices, !prices.isEmpty { Text("Video prices: " + prices.joined(separator: ", ")).font(.caption) }
                    if let evidence = candidate.evidence, !evidence.isEmpty { Text(evidence.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                        }.font(.caption)
                    }
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
            catch { store.report(error) }
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

struct RSVPButtons: View {
    var selected: String?
    var busy: Bool
    var action: (String) -> Void
    static func prompt(for response: String?) -> String {
        switch response {
        case "going": return "You’re going"
        case "maybe": return "Maybe"
        case "declined": return "You can’t go"
        default: return "Are you coming?"
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { options }
            VStack(spacing: 8) { options }
        }
    }
    @ViewBuilder private var options: some View {
        ForEach(["going", "maybe", "declined"], id: \.self) { status in
            Button { action(status) } label: {
                HStack(spacing: 5) {
                    if selected == status { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                    Text(status == "going" ? "Yes" : status == "maybe" ? "Maybe" : "No").font(.body.weight(.semibold)).fixedSize(horizontal: true, vertical: false)
                }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selected == status ? PalTheme.onAccent : PalTheme.ink)
                    .background(selected == status ? PalTheme.accent : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).disabled(busy).accessibilityValue(selected == status ? "Selected" : "Not selected")
        }
    }
}

struct RSVPCardView: View {
    let group: ChatGroup
    let planID: UUID
    @EnvironmentObject private var store: PalStore
    @State private var busy = false
    @State private var issue: String?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var plan: GroupPlan? { state.plans.first { $0.id == planID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan {
                NavigationLink { PlanDetailView(group: group, plan: plan) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image("DoodleCalendar").renderingMode(.template).resizable().scaledToFit().frame(width: 32, height: 32).foregroundStyle(PalTheme.accentText).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan.title).font(.headline).foregroundStyle(.primary)
                            Text(plan.startsAt.flatMap(PalDate.date)?.formatted(date: .abbreviated, time: .shortened) ?? "Time to be decided").font(.subheadline).foregroundStyle(.secondary)
                            if let place = state.places.first(where: { $0.id == plan.placeID }) {
                                Text(place.name).font(.subheadline).foregroundStyle(.secondary)
                                if let address = place.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                            }
                            if plan.status != "confirmed" { Text(plan.status.capitalized).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).accessibilityHint("Plan details")
                if plan.status == "draft" {
                    NavigationLink { PlanDetailView(group: group, plan: plan) } label: {
                        Label(plan.startsAt.flatMap(PalDate.date).map { $0 > Date() } == true ? "Review and confirm plan" : "Review plan", systemImage: "arrow.right")
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.foregroundStyle(.primary)
                }
                if plan.canRSVP() {
                    Text(RSVPButtons.prompt(for: plan.response(for: store.userID))).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    RSVPButtons(selected: plan.response(for: store.userID), busy: busy) { status in
                        guard !busy else { return }; busy = true; issue = nil
                        Task {
                            defer { busy = false }
                            do { try await store.mutate(group, action: "plan.rsvp", data: ["id": .string(plan.id.uuidString), "status": .string(status)]) }
                            catch { if !PalCancellation.isCancellation(error) { issue = "Couldn’t save your response. Try again." } }
                        }
                    }
                } else if plan.status != "draft" { Text(plan.status == "cancelled" ? "This plan was cancelled." : "RSVP closed").font(.subheadline).foregroundStyle(.secondary) }
                if plan.status != "draft" {
                    Text(plan.attendanceSummary(memberCount: state.members.count)).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Who’s coming") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(state.members) { member in
                                NavigationLink { MemberDetailView(groupID: group.id, member: member) } label: {
                                HStack(spacing: 8) {
                                    AvatarView(name: member.displayName ?? "Member", url: member.avatarURL, size: 36)
                                    Text(member.displayName ?? "Member").font(.caption.weight(.medium))
                                    Spacer(minLength: 8)
                                    let response = plan.response(for: member.userID)
                                    Text(response == "going" ? "Going" : response == "maybe" ? "Maybe" : response == "declined" ? "Not going" : "No reply").font(.caption).foregroundStyle(.secondary)
                                }.frame(minHeight: 44).foregroundStyle(.primary)
                                }.buttonStyle(.plain).accessibilityHint("Member details")
                            }
                        }.padding(.top, 6)
                    }.font(.subheadline)
                }
                if let bookingStatus = plan.bookingStatus {
                    Label(bookingStatus == "booked" ? "Reservation confirmed" : bookingStatus == "requested" ? "Reservation pending" : bookingStatus == "failed" ? "Reservation not completed" : "Not booked", systemImage: "fork.knife").font(.caption).foregroundStyle(.secondary)
                }
                if let issue { Text(issue).font(.caption).foregroundStyle(PalTheme.error) }
            } else { CardRecordStatusView(group: group, title: "Plan") }
        }.task { if plan == nil { try? await store.loadState(group) } }
    }
}
