import SwiftUI

struct MemberDetailView: View {
    let groupID: UUID
    let member: GroupMember
    @EnvironmentObject private var store: PalStore
    @State private var fetching = PalFetchState()
    private var key: String { MemberSummary.key(groupID: groupID, userID: member.userID) }
    private var summary: MemberSummary? { store.memberSummaries[key] }
    private var state: GroupState? { store.states[groupID] }
    private var person: GroupMember { state?.members.first { $0.userID == member.userID } ?? member }
    private var name: String { person.displayName ?? "Member" }
    private var availability: [GroupMemory] {
        (state?.memories ?? summary?.availability ?? []).filter { $0.isCurrentAvailability(for: member.userID) }
    }
    private var preferences: [GroupMemory] {
        (state?.memories ?? summary?.preferences ?? []).filter { $0.kind == "preference" && $0.userID == member.userID }
    }
    private var plans: [GroupPlan] {
        (state?.plans ?? []).filter { plan in
            plan.status == "confirmed" && (plan.endsAt ?? plan.startsAt).flatMap(PalDate.date).map { $0 > Date() } == true &&
            ["going", "maybe"].contains(plan.response(for: member.userID) ?? "")
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 12) {
                    AvatarView(name: name, url: person.avatarURL, size: 88)
                    Text(name).font(.title2.weight(.semibold))
                    Text("In this group").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 12)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Pal’s take").font(.headline)
                    if let text = summary?.summary {
                        Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                    } else if summary != nil {
                        Text("Still getting to know \(name). More conversation, fewer guesses.").foregroundStyle(.secondary)
                    }
                    if summary == nil || fetching.issue != nil {
                        PalFetchStatusView(state: fetching, hasContent: summary != nil) { Task { await refresh() } }
                    }
                    if let sources = summary?.sources, !sources.isEmpty {
                        DisclosureGroup("From the conversation") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(sources) { source in Text(source.body).font(.subheadline).foregroundStyle(.secondary) }
                            }.padding(.top, 8)
                        }.font(.footnote).tint(PalTheme.ink)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Availability").font(.headline)
                    if state == nil && summary == nil {
                        PalFetchStatusView(state: store.stateFetch[groupID] ?? PalFetchState(), hasContent: false) { Task { await loadGroup() } }
                    } else if availability.isEmpty {
                        Text("No availability shared yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(availability) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.value).font(.body)
                                if let until = item.expiresAt.flatMap(PalDate.date) {
                                    Text("Shared for \(until.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("Only what they’ve shared here. Their private calendar stays private.").font(.caption).foregroundStyle(.secondary)
                }

                if !plans.isEmpty, let group = store.groups.first(where: { $0.id == groupID }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Upcoming plans").font(.headline)
                        ForEach(plans) { plan in
                            NavigationLink { PlanDetailView(group: group, plan: plan) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(plan.title).foregroundStyle(.primary)
                                        if let date = plan.startsAt.flatMap(PalDate.date) {
                                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(plan.response(for: member.userID) == "going" ? "Going" : "Maybe").font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                    }
                }

                if !preferences.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shared preferences").font(.headline)
                        ForEach(preferences) { item in Text(item.value).font(.body) }
                    }
                }
            }.padding(20)
        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .task {
                async let details: Void = loadGroup()
                await refresh()
                await details
            }
            .refreshable { await refresh() }
    }
    private func refresh() async {
        fetching.begin()
        do {
            let data = try await store.api("/api/groups/\(groupID)/members/\(member.userID)/summary")
            let loaded = try JSONDecoder().decode(MemberSummary.self, from: data)
            try Task.checkCancellation()
            store.memberSummaries[key] = loaded
            fetching.finish()
        } catch { fetching.fail(error) }
    }
    private func loadGroup() async {
        guard let group = store.groups.first(where: { $0.id == groupID }) else { return }
        do { try await store.loadState(group) }
        catch { /* The store preserves the snapshot and exposes stateFetch for inline retry. */ }
    }
}
