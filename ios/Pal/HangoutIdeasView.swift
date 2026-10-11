import SwiftUI

struct HangoutIdea: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let place: GroupPlace?
    let sources: [GroupSource]
    var thumbnail: URL? { sources.lazy.compactMap(\.thumbnailURL).first }
    var emoji: String {
        let text = title.lowercased()
        if ["coffee", "cafe", "café", "咖啡"].contains(where: text.contains) { return "☕️" }
        if ["park", "hike", "hiking", "walk", "公園", "步道"].contains(where: text.contains) { return "🌳" }
        return "🍽️"
    }

    static func saved(in state: GroupState) -> [HangoutIdea] {
        var ideas: [HangoutIdea] = []
        var linkedSources = Set<UUID>()
        var savedPlaces = Set<UUID>()
        for place in state.places.reversed() {
            let sources = state.sources.filter { source in
                source.placeID == place.id || source.placeIDs?.contains(place.id) == true || place.contributors?.contains(where: { $0.sourceID == source.id }) == true
            }
            linkedSources.formUnion(sources.map(\.id))
            savedPlaces.insert(place.id)
            let dishes = sources.lazy.compactMap { source in
                source.candidates?.first(where: { $0.name.localizedCaseInsensitiveCompare(place.name) == .orderedSame })?.dishes?.prefix(3).joined(separator: ", ")
            }.first
            let detail = [place.address, dishes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            ideas.append(HangoutIdea(id: "place:\(place.id)", title: place.name, subtitle: detail.isEmpty ? nil : detail, place: place, sources: sources))
        }
        for source in state.sources.reversed() where !linkedSources.contains(source.id) {
            let names = (source.candidates ?? []).map(\.name).filter { !$0.isEmpty }.joined(separator: " · ")
            let title = names.isEmpty ? (source.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Shared idea") : names
            let candidate = source.candidates?.first
            let detail = [candidate?.city, candidate?.dishes?.prefix(3).joined(separator: ", ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            ideas.append(HangoutIdea(id: "source:\(source.id)", title: title, subtitle: detail.isEmpty ? nil : detail, place: nil, sources: [source]))
        }
        var labels = Set<String>()
        for poll in state.polls.reversed() where poll.kind == "place" {
            for option in poll.options {
                if let placeID = option.placeID, savedPlaces.contains(placeID) { continue }
                let key = option.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, labels.insert(key).inserted else { continue }
                ideas.append(HangoutIdea(id: "option:\(poll.id):\(option.id)", title: option.label, subtitle: poll.question, place: nil, sources: []))
            }
        }
        return ideas
    }
}

struct HangoutIdeasView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    private var ideas: [HangoutIdea] { HangoutIdea.saved(in: store.states[group.id] ?? .empty) }
    private var fetch: PalFetchState { store.stateFetch[group.id] ?? PalFetchState() }
    var body: some View {
        List {
            if let issue = fetch.issue {
                Section {
                    HStack {
                        Text(ideas.isEmpty ? "Couldn’t load ideas." : "Your saved ideas are here. Updates are paused.").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await refresh() } }.disabled(fetch.isLoading)
                    }.accessibilityHint(issue)
                }
            }
            if !ideas.isEmpty {
                ForEach(ideas) { idea in
                    NavigationLink { HangoutIdeaDetailView(group: group, idea: idea) } label: {
                        HangoutIdeaRow(idea: idea)
                    }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            } else if store.states[group.id] == nil && fetch.issue == nil {
                ForEach(0..<3, id: \.self) { _ in
                    HangoutIdeaRow(idea: HangoutIdea(id: "loading", title: "A shared hangout idea", subtitle: "Saved from your chat", place: nil, sources: []))
                        .redacted(reason: .placeholder).accessibilityHidden(true)
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            } else if fetch.issue == nil {
                ContentUnavailableView("No ideas yet", systemImage: "bookmark", description: Text("Share a link in this chat. Pal keeps the ideas here."))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Color(uiColor: .systemBackground)).navigationTitle("Hangout Ideas").navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task { if store.states[group.id] == nil { await refresh() } }
    }
    private func refresh() async { try? await store.loadState(group) }
}

struct HangoutIdeaRow: View {
    let idea: HangoutIdea
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let thumbnail = idea.thumbnail {
                PalCachedAvatarImage(url: thumbnail).frame(width: 60, height: 60)
                    .background(Color(uiColor: .tertiarySystemFill)).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
            } else {
                Text(idea.emoji).font(.title).frame(width: 60, height: 60)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(idea.title).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let subtitle = idea.subtitle, !subtitle.isEmpty { Text(subtitle).font(.subheadline).lineLimit(2).foregroundStyle(.secondary) }
                if idea.place == nil, let source = idea.sources.first {
                    if ["pending", "resolving"].contains(source.status) { Text("Inspecting…").font(.caption).foregroundStyle(.secondary) }
                    else if source.status == "needs_confirmation" { Text("Location needs checking").font(.caption).foregroundStyle(.secondary) }
                    else if source.status == "failed" { Text("Details unavailable").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).frame(minHeight: 92)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
    }
}

struct HangoutIdeaDetailView: View {
    let group: ChatGroup
    let idea: HangoutIdea
    @EnvironmentObject private var store: PalStore
    private var current: HangoutIdea { HangoutIdea.saved(in: store.states[group.id] ?? .empty).first { $0.id == idea.id } ?? idea }
    var body: some View {
        List {
            Section {
                if let thumbnail = current.thumbnail {
                    PalCachedAvatarImage(url: thumbnail).frame(maxWidth: .infinity).frame(height: 220)
                        .background(Color(uiColor: .tertiarySystemFill)).clipped().accessibilityHidden(true)
                }
                Text(current.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let subtitle = current.subtitle { Text(subtitle).foregroundStyle(.secondary).textSelection(.enabled) }
                if let place = current.place {
                    ContributorLine(group: group, contributors: place.contributors)
                    NavigationLink("Place details & directions") { PlaceDetailView(group: group, place: place) }
                }
            }
            ForEach(current.sources) { source in
                Section("Shared link") {
                    ContributorLine(group: group, contributors: source.contributors)
                    if let title = source.title, title != current.title { Text(title).font(.subheadline).textSelection(.enabled) }
                    if case .string(let description)? = source.metadata?["description"], !description.isEmpty, description != source.title {
                        DisclosureGroup("Source details") { Text(String(description.prefix(1500))).font(.footnote).textSelection(.enabled) }
                    }
                    if let url = source.url.flatMap({ URL(string: $0) }), ["http", "https"].contains(url.scheme ?? "") {
                        Link("Open original", destination: url)
                    }
                    if ["pending", "resolving"].contains(source.status) { Text("Details are still being checked.").font(.footnote).foregroundStyle(.secondary) }
                    else if source.status == "failed" { Text("This link is saved. Pal couldn’t inspect its details.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(Array((source.candidates ?? []).enumerated()), id: \.offset) { _, candidate in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(candidate.name).font(.headline)
                            if let address = candidate.address ?? candidate.city { Text(address).font(.subheadline).foregroundStyle(.secondary) }
                            if let dishes = candidate.dishes, !dishes.isEmpty { Text(dishes.joined(separator: ", ")).font(.subheadline) }
                            if let prices = candidate.prices, !prices.isEmpty { Text("Source mentions: " + prices.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary) }
                            if let evidence = candidate.evidence, !evidence.isEmpty { Text(evidence.joined(separator: "\n")).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if source.status == "needs_confirmation" || source.status == "failed" {
                        NavigationLink("Check the place") { SourceCardView(group: group, source: source).padding().navigationTitle("Shared place").navigationBarTitleDisplayMode(.inline) }
                    }
                }
            }
        }.navigationTitle("Idea").navigationBarTitleDisplayMode(.inline)
    }
}
