import SwiftUI
import MapKit

struct PlaceSearchView: View {
    private struct SearchPlace: Decodable, Identifiable {
        let providerID: String
        let provider: String
        let name: String
        let address: String?
        let latitude: Double
        let longitude: Double
        let website: String?
        var id: String { providerID }
        enum CodingKeys: String, CodingKey {
            case name, address, latitude, longitude, website, provider
            case providerID = "provider_id"
        }
    }
    let group: ChatGroup
    var correctingID: UUID? = nil
    var sourceID: UUID? = nil
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [SearchPlace] = []
    @State private var busy = false
    @State private var saving = false
    @State private var searched = false
    @State private var searchIssue: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if busy { ProgressView("Searching…") }
            if let searchIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(searchIssue).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again", action: find).disabled(busy)
                }
            }
            if searched && items.isEmpty && !busy && searchIssue == nil { ContentUnavailableView.search(text: query) }
            ForEach(items) { item in
                Button { save(item) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).foregroundStyle(.primary)
                        if let address = item.address { Text(address).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }.disabled(busy)
            }
            if !searched { Text("Search for the exact restaurant or place.").foregroundStyle(.secondary) }
        }
        .navigationTitle(correctingID == nil ? "Save a place" : "Correct place")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Restaurant, place or address")
        .onSubmit(of: .search) { find() }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
        .onDisappear { searchTask?.cancel(); searchTask = nil }
    }

    private func find() {
        guard !saving else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searchTask?.cancel()
        var components = URLComponents()
        components.path = "/api/places/search"
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let path = components.string else { return }
        busy = true
        searchIssue = nil
        searchTask = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                struct Response: Decodable { let places: [SearchPlace] }
                let data = try await store.api(path)
                guard !Task.isCancelled else { return }
                items = try JSONDecoder().decode(Response.self, from: data).places
                searched = true
            } catch is CancellationError {} catch {
                if !Task.isCancelled && !PalCancellation.isCancellation(error) { searchIssue = error.localizedDescription }
            }
        }
    }

    private func save(_ item: SearchPlace) {
        busy = true
        saving = true
        Task {
            defer { busy = false; saving = false }
            do {
                var data: [String: JSONValue] = ["name": .string(item.name), "provider_id": .string(item.providerID),
                    "latitude": .number(item.latitude), "longitude": .number(item.longitude), "provider": .string(item.provider), "address": .string(item.address ?? "")]
                if let correctingID { data["id"] = .string(correctingID.uuidString) }
                if correctingID == nil, let sourceID { data["source_id"] = .string(sourceID.uuidString) }
                if let website = item.website { data["website"] = .string(website) }
                try await store.mutate(group, action: correctingID == nil ? "place.save" : "place.correct", data: data)
                dismiss()
            } catch { store.report(error) }
        }
    }
}

struct PlaceDetailView: View {
    let group: ChatGroup
    let place: GroupPlace
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var correcting = false
    @State private var deleting = false
    @State private var busy = false
    private var current: GroupPlace { (store.states[group.id] ?? .empty).places.first { $0.id == place.id } ?? place }
    var body: some View {
        List {
            Section {
                Text(current.name).font(.title2.bold())
                ContributorLine(group: group, contributors: current.contributors)
                if let address = current.address { Text(address).foregroundStyle(.secondary) }
                if let latitude = current.latitude, let longitude = current.longitude {
                    Button("Directions in Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
                        item.name = current.name
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    }
                }
                if let website = current.website, let url = URL(string: website), ["http", "https"].contains(url.scheme) {
                    Link("Website", destination: url).tint(PalTheme.accentText)
                }
                if let booking = current.bookingURL, let url = URL(string: booking), ["http", "https"].contains(url.scheme) {
                    Link("Open booking website", destination: url).tint(PalTheme.accentText)
                }
            }
            if current.status != "resolved" {
                Section("Confirm the right place") {
                    Text("Pal needs you to check this location before saving it.").font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(current.candidates.enumerated()), id: \.offset) { _, candidate in
                        Button { confirm(candidate) } label: {
                            VStack(alignment: .leading) {
                                Text(candidate.name)
                                if let address = candidate.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.disabled(busy || candidate.latitude == nil || candidate.longitude == nil || candidate.providerID == nil)
                    }
                }
            }
            Section {
                Button("Search for the correct place", systemImage: "magnifyingglass") { correcting = true }
                Button("Remove saved place", systemImage: "trash", role: .destructive) { deleting = true }
            }
        }.navigationTitle("Place").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $correcting) { NavigationStack { PlaceSearchView(group: group, correctingID: place.id) } }
        .confirmationDialog("Remove this place from the group?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Remove place", role: .destructive) { mutate("place.delete", ["id": .string(place.id.uuidString)], close: true) }
        }
    }
    private func confirm(_ candidate: PlaceCandidate) {
        var data: [String: JSONValue] = ["id": .string(place.id.uuidString), "name": .string(candidate.name), "provider": .string(candidate.provider ?? "apple"), "address": .string(candidate.address ?? "")]
        if let value = candidate.latitude { data["latitude"] = .number(value) }
        if let value = candidate.longitude { data["longitude"] = .number(value) }
        if let value = candidate.providerID { data["provider_id"] = .string(value) }
        mutate("place.correct", data)
    }
    private func mutate(_ action: String, _ data: [String: JSONValue], close: Bool = false) {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.mutate(group, action: action, data: data); if close { dismiss() } }
            catch { store.report(error) }
        }
    }
}

struct GroupCalendarView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var dayHeight: CGFloat = 44
    @State private var anchor = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var page = 0
    @State private var monthPages = Array(-12...12)
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var preferredDay = Calendar.current.component(.day, from: Date())
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var month: Date { date(for: page) }
    static func monthDays(for month: Date, calendar: Calendar = .current) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month), let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let offset = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let dates: [Date?] = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }
        let leading: [Date?] = Array(repeating: nil, count: offset)
        // All pages occupy six weeks, so changing months never jumps the agenda.
        return leading + dates + Array(repeating: nil, count: max(0, 42 - offset - dates.count))
    }
    static func selection(in month: Date, preferredDay: Int, calendar: Calendar = .current) -> Date? {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let days = calendar.range(of: .day, in: .month, for: start) else { return nil }
        return calendar.date(byAdding: .day, value: min(max(1, preferredDay), days.count) - 1, to: start)
    }
    private var weekdays: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let start = Calendar.current.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }
    private func onDay(_ date: String?) -> Bool { date.flatMap(PalDate.date).map { Calendar.current.isDate($0, inSameDayAs: selected) } ?? false }
    private func hasEvents(_ date: Date) -> Bool {
        state.plans.contains { $0.status != "cancelled" && $0.startsAt.flatMap(PalDate.date).map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false }
            || state.reminders.contains { $0.status != "cancelled" && PalDate.date($0.dueAt).map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false }
    }
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    HStack {
                        Button("Previous month", systemImage: "chevron.left") { moveMonth(-1) }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        Spacer()
                        Text(month.formatted(.dateTime.month(.wide).year())).font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Next month", systemImage: "chevron.right") { moveMonth(1) }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    HStack(spacing: 0) {
                        ForEach(weekdays.indices, id: \.self) { index in
                            Text(weekdays[index]).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }.accessibilityHidden(true)
                    TabView(selection: $page) {
                        ForEach(monthPages, id: \.self) { index in
                            monthGrid(for: date(for: index)).tag(index)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: dayHeight * 6 + 40)
                }.buttonStyle(.plain)
            }
            Section(selected.formatted(date: .abbreviated, time: .omitted)) {
                let plans = state.plans.filter { $0.status != "cancelled" && onDay($0.startsAt) }
                let reminders = state.reminders.filter { $0.status != "cancelled" && onDay($0.dueAt) }
                if store.states[group.id] == nil || store.stateFetch[group.id]?.issue != nil {
                    PalFetchStatusView(state: store.stateFetch[group.id] ?? PalFetchState(), hasContent: store.states[group.id] != nil) { Task { await refresh() } }
                }
                if store.states[group.id] != nil && plans.isEmpty && reminders.isEmpty {
                    VStack(spacing: 10) {
                        Image("DoodleCalendar").renderingMode(.template).resizable().scaledToFit()
                            .frame(width: 64, height: 64).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("Nothing planned for this day.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                ForEach(plans) { plan in planLink(plan) }
                ForEach(reminders) { reminderLink($0) }
            }
            let upcoming = state.plans.filter { $0.status != "cancelled" && ($0.startsAt.flatMap(PalDate.date) ?? .distantFuture) >= Calendar.current.startOfDay(for: Date()) }
            let scheduled = state.reminders.filter { $0.status == "scheduled" }
            if !upcoming.isEmpty || !scheduled.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming.sorted { ($0.startsAt.flatMap(PalDate.date) ?? .distantFuture) < ($1.startsAt.flatMap(PalDate.date) ?? .distantFuture) }) { plan in planLink(plan) }
                    ForEach(scheduled.sorted { (PalDate.date($0.dueAt) ?? .distantFuture) < (PalDate.date($1.dueAt) ?? .distantFuture) }) { reminderLink($0) }
                }
            }
            let past = state.plans.filter { $0.status == "cancelled" || ($0.startsAt.flatMap(PalDate.date) ?? .distantFuture) < Calendar.current.startOfDay(for: Date()) }
            if !past.isEmpty {
                Section("Past and cancelled") { ForEach(past) { plan in planLink(plan) } }
            }
        }.navigationTitle("Calendar").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Today", action: showToday) } }
        .onChange(of: page) { _, value in
            extendPages(near: value)
            if let day = Self.selection(in: date(for: value), preferredDay: preferredDay) { selected = day }
        }
        .refreshable { await refresh() }.task { await refresh() }
    }
    private func monthGrid(for month: Date) -> some View {
        let days = Self.monthDays(for: month)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
            ForEach(days.indices, id: \.self) { index in
                if let date = days[index] {
                    let active = Calendar.current.isDate(date, inSameDayAs: selected)
                    Button {
                        selected = date
                        preferredDay = Calendar.current.component(.day, from: date)
                    } label: {
                        VStack(spacing: 3) {
                            Text("\(Calendar.current.component(.day, from: date))").font(.body).lineLimit(1).minimumScaleFactor(0.65)
                            Circle().fill(hasEvents(date) ? (active ? PalTheme.onAccent : PalTheme.accentText) : .clear).frame(width: 4, height: 4)
                        }.frame(maxWidth: .infinity, minHeight: dayHeight)
                            .foregroundStyle(active ? PalTheme.onAccent : PalTheme.ink)
                            .background(active ? PalTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                        .accessibilityValue(hasEvents(date) ? "Has plans" : "")
                        .accessibilityAddTraits(active ? .isSelected : [])
                } else { Color.clear.frame(height: dayHeight).accessibilityHidden(true) }
            }
        }.padding(.horizontal, 2)
    }
    private func planLink(_ plan: GroupPlan) -> some View {
        NavigationLink { PlanDetailView(group: group, plan: plan) } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title).foregroundStyle(.primary)
                    Text(plan.startsAt.flatMap(PalDate.date)?.formatted(date: .abbreviated, time: .shortened) ?? "Time to be decided")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(plan.status.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "calendar").foregroundStyle(PalTheme.ink) }
        }
    }
    private func reminderLink(_ reminder: GroupReminder) -> some View {
        NavigationLink { ReminderEditor(group: group, reminder: reminder) } label: {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reminder.body).foregroundStyle(.primary)
                    Text(PalDate.date(reminder.dueAt)?.formatted(date: .abbreviated, time: .shortened) ?? reminder.dueAt).font(.caption).foregroundStyle(.secondary)
                    Text(reminder.status.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "bell").foregroundStyle(.secondary) }
        }
    }
    private func date(for page: Int) -> Date { Calendar.current.date(byAdding: .month, value: page, to: anchor) ?? anchor }
    private func extendPages(near page: Int) {
        if let first = monthPages.first, page <= first + 2 { monthPages.insert(contentsOf: (first - 12)..<first, at: 0) }
        if let last = monthPages.last, page >= last - 2 { monthPages.append(contentsOf: (last + 1)...(last + 12)) }
    }
    private func moveMonth(_ delta: Int) {
        let next = page + delta
        extendPages(near: next)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page = next }
    }
    private func showToday() {
        let today = Date()
        preferredDay = Calendar.current.component(.day, from: today)
        selected = Calendar.current.startOfDay(for: today)
        if let start = Calendar.current.dateInterval(of: .month, for: today)?.start,
           let offset = Calendar.current.dateComponents([.month], from: anchor, to: start).month {
            extendPages(near: offset)
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { page = offset }
        }
    }
    private func refresh() async { do { try await store.loadState(group) } catch { /* State status supplies retry while preserving the calendar. */ } }
}

struct PlanDetailView: View {
    let group: ChatGroup
    let plan: GroupPlan
    @EnvironmentObject private var store: PalStore
    @State private var editing = false
    @State private var busy = false
    @State private var cancelling = false
    @State private var bookingReference = ""
    @State private var recordingBooking = false
    @State private var calendarDraft: AppleCalendarDraft?
    @State private var savedCalendarVersion: Int?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var current: GroupPlan { state.plans.first { $0.id == plan.id } ?? plan }
    private var place: GroupPlace? { state.places.first { $0.id == current.placeID } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 14) {
                        PlanDateBadge(date: current.startsAt.flatMap(PalDate.date))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(current.status == "draft" ? "Proposed plan" : current.status.capitalized).font(.subheadline).foregroundStyle(.secondary)
                            Text(current.title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let date = current.startsAt.flatMap(PalDate.date) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(date.formatted(date: .complete, time: .omitted)).font(.headline)
                            Text(date.formatted(date: .omitted, time: .shortened) + (current.endsAt.flatMap(PalDate.date).map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                                .font(.title3).fixedSize(horizontal: false, vertical: true)
                            Text(TimeZone.current.abbreviation(for: date) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    } else { Text("Time to be decided").foregroundStyle(.secondary) }
                    if let place {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(place.name).font(.headline)
                            if let address = place.address { Text(address).font(.subheadline).foregroundStyle(.secondary) }
                            if let latitude = place.latitude, let longitude = place.longitude {
                                Button("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") {
                                    let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
                                    item.name = place.name
                                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                                }.font(.subheadline).tint(PalTheme.ink).frame(minHeight: 44)
                            }
                        }
                    }
                    if let notes = current.notes, !notes.isEmpty { Text(notes).font(.body).foregroundStyle(.secondary) }
                }
                if let issue = store.stateFetch[group.id]?.issue {
                    HStack { Text("Showing saved details.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Retry") { Task { try? await store.loadState(group) } }.accessibilityHint(issue) }
                }
                if current.status == "draft" {
                    if current.startsAt.flatMap(PalDate.date).map({ $0 > Date() }) == true {
                        Text("Confirm the plan. Everyone RSVPs separately.").font(.subheadline).foregroundStyle(.secondary)
                        Button { action("plan.confirm") } label: { Text("Confirm plan").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.borderedProminent).tint(PalTheme.accent).foregroundStyle(PalTheme.onAccent).disabled(busy)
                    } else {
                        Text(current.startsAt == nil ? "Choose a time before confirming." : "This proposed time has passed.").font(.subheadline).foregroundStyle(.secondary)
                        Button { editing = true } label: { Text("Update plan").font(.headline).frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.borderedProminent).tint(PalTheme.accent).foregroundStyle(PalTheme.onAccent).disabled(busy)
                    }
                }
                if current.canRSVP() {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(RSVPButtons.prompt(for: current.response(for: store.userID))).font(.title3.weight(.semibold))
                        RSVPButtons(selected: current.response(for: store.userID), busy: busy) { action("plan.rsvp", ["status": .string($0)]) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(current.status == "draft" ? "Group members" : current.attendanceSummary(memberCount: state.members.count)).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(state.members) { member in
                        NavigationLink { MemberDetailView(groupID: group.id, member: member) } label: {
                        HStack(spacing: 12) {
                            AvatarView(name: member.displayName ?? "Member", url: member.avatarURL, size: 40)
                            Text(member.userID == store.userID ? "You" : member.displayName ?? "Member")
                            Spacer()
                            let status = current.response(for: member.userID)
                            if current.status != "draft" { Text(status == "going" ? "Going" : status == "maybe" ? "Maybe" : status == "declined" ? "Can’t go" : "No reply").font(.subheadline).foregroundStyle(status == "going" ? PalTheme.accentText : .secondary) }
                        }.frame(minHeight: 44).foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                    }
                }
                if let place, (current.status == "confirmed" && place.bookingURL != nil) || current.bookingStatus == "booked" {
                    DisclosureGroup("Reservation", isExpanded: $recordingBooking) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(current.bookingStatus == "booked" ? "Reservation confirmed" : current.bookingStatus == "requested" ? "Reservation pending" : current.bookingStatus == "failed" ? "Reservation not completed" : "Not booked").font(.subheadline).foregroundStyle(.secondary)
                            if let reference = current.bookingReference, !reference.isEmpty { Text(reference).font(.body).textSelection(.enabled) }
                            if current.canRSVP() {
                            if let link = place.bookingURL, let url = URL(string: link), ["https", "http"].contains(url.scheme) {
                                Link("Open booking page", destination: url).frame(minHeight: 44).tint(PalTheme.ink)
                            }
                            TextField("Confirmation reference (optional)", text: $bookingReference).textFieldStyle(.roundedBorder)
                            if current.bookingStatus == "booked" {
                                Button("Update confirmation") { action("plan.booking", ["status": .string("booked"), "reference": .string(bookingReference)]) }.disabled(busy)
                                Button("Reservation still needed") { action("plan.booking", ["status": .string("needed")]) }.disabled(busy)
                            } else {
                                Text("Book on the website, then record the confirmation here.").font(.footnote).foregroundStyle(.secondary)
                                Button("Mark as booked") { action("plan.booking", ["status": .string("booked"), "reference": .string(bookingReference)]) }.disabled(busy)
                            }
                            }
                        }.padding(.top, 12)
                    }.font(.headline).tint(PalTheme.ink)
                }
                if savedCalendarVersion != nil || (current.canRSVP() && current.response(for: store.userID) == "going") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let savedCalendarVersion {
                            Label("Saved to Apple Calendar", systemImage: "checkmark.circle").font(.subheadline)
                            if current.status == "cancelled" || current.response(for: store.userID) != "going" { Text("Remove the Calendar copy if you no longer need it.").font(.footnote).foregroundStyle(.secondary) }
                            else if savedCalendarVersion != (current.version ?? 1) { Text("This plan changed. Update its existing Calendar copy.").font(.footnote).foregroundStyle(.secondary) }
                        } else { Button("Add to Apple Calendar", systemImage: "calendar.badge.plus", action: reviewCalendarCopy).frame(minHeight: 44).disabled(busy) }
                        Text("Later changes stay in Pal.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if busy { ProgressView().frame(maxWidth: .infinity) }
            }.padding(20)
        }.navigationTitle("Plan").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if current.status != "cancelled" { ToolbarItem(placement: .topBarTrailing) {
                Menu { Button("Edit plan", systemImage: "pencil") { editing = true }; Button("Cancel plan", systemImage: "xmark", role: .destructive) { cancelling = true } } label: { Image(systemName: "ellipsis") }.disabled(busy).accessibilityLabel("Plan actions")
            } }
        }
        .task { try? await store.loadState(group) }
        .refreshable { try? await store.loadState(group) }
        .onAppear {
            bookingReference = current.bookingReference ?? ""
            if let userID = store.userID { savedCalendarVersion = AppleCalendarReceipt.savedVersion(userID: userID, planID: plan.id) }
        }
        .sheet(item: $calendarDraft) { draft in
            AppleCalendarEditor(draft: draft) { result in
                if store.userID == draft.userID, AppleCalendarReceipt.record(action: result, userID: draft.userID, planID: draft.planID, version: draft.version) { savedCalendarVersion = draft.version }
                calendarDraft = nil
            }
        }
        .sheet(isPresented: $editing) { NavigationStack { PlanEditor(group: group, plan: current) } }
        .confirmationDialog("Cancel this group plan?", isPresented: $cancelling, titleVisibility: .visible) { Button("Cancel plan", role: .destructive) { action("plan.cancel") } }
    }
    private func reviewCalendarCopy() {
        guard let userID = store.userID, savedCalendarVersion == nil else { return }
        do { calendarDraft = try AppleCalendarDraft(plan: current, group: group, state: state, userID: userID) } catch { store.report(error) }
    }
    private func action(_ name: String, _ extra: [String: JSONValue] = [:]) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await store.mutate(group, action: name, data: extra.merging(["id": .string(plan.id.uuidString)]) { _, new in new }) } catch { store.report(error) }
        }
    }
}

struct PlanEditor: View {
    let group: ChatGroup
    var plan: GroupPlan? = nil
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var starts = Date().addingTimeInterval(3600)
    @State private var ends = Date().addingTimeInterval(7200)
    @State private var placeID: UUID?
    @State private var notes = ""
    @State private var busy = false
    var body: some View {
        Form {
            TextField("Plan title", text: $title)
            DatePicker("Starts", selection: $starts)
            DatePicker("Ends", selection: $ends, in: starts...)
            Picker("Place", selection: $placeID) {
                Text("Not decided").tag(UUID?.none)
                ForEach((store.states[group.id] ?? .empty).places) { place in Text(place.name).tag(Optional(place.id)) }
            }
            TextField("Notes", text: $notes, axis: .vertical).lineLimit(3...6)
            if ends <= starts { Text("The end must be after the start.").foregroundStyle(PalTheme.error) }
            if busy { ProgressView() }
        }.disabled(busy).navigationTitle(plan == nil ? "New plan" : "Edit plan").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 160 || ends <= starts) }
        }
        .onAppear {
            guard let plan else { return }
            title = plan.title; notes = plan.notes ?? ""; placeID = plan.placeID
            if let date = plan.startsAt.flatMap(PalDate.date) { starts = date }
            ends = plan.endsAt.flatMap(PalDate.date) ?? starts.addingTimeInterval(3600)
        }
        .onChange(of: starts) { _, date in if ends <= date { ends = date.addingTimeInterval(3600) } }
    }
    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                var data: [String: JSONValue] = ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "starts_at": .string(PalDate.iso(starts)),
                    "ends_at": .string(PalDate.iso(ends)), "notes": .string(notes), "place_id": placeID.map { .string($0.uuidString) } ?? .null]
                if let plan { data["id"] = .string(plan.id.uuidString) }
                try await store.mutate(group, action: plan == nil ? "plan.create" : "plan.update", data: data)
                dismiss()
            } catch { store.report(error) }
        }
    }
}

struct ReminderEditor: View {
    let group: ChatGroup
    var reminder: GroupReminder? = nil
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var due = Date().addingTimeInterval(3600)
    @State private var sourceKey = UUID().uuidString
    @State private var creationData: [String: JSONValue]?
    @State private var busy = false
    @State private var cancelling = false
    private var current: GroupReminder? {
        guard let reminder else { return nil }
        return (store.states[group.id] ?? .empty).reminders.first { $0.id == reminder.id } ?? reminder
    }
    private var editable: Bool {
        current?.canEdit(userID: store.userID) ?? true
    }
    private var valid: Bool {
        let text = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.utf16.count <= 2000 && due > Date()
    }
    var body: some View {
        Form {
            if reminder == nil {
                Image("DoodleReminder").renderingMode(.template).resizable().scaledToFit()
                    .frame(height: 64).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    .accessibilityHidden(true).listRowBackground(Color.clear)
            }
            if editable {
                TextField("What should Pal remind the group?", text: $bodyText, axis: .vertical)
                    .lineLimit(2...5).disabled(creationData != nil)
                if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > 2000 {
                    Text("Use 2,000 characters or fewer.").font(.footnote).foregroundStyle(PalTheme.error)
                }
                DatePicker("Remind at", selection: $due, in: Date()...).disabled(creationData != nil)
            } else if let current {
                Text(current.body)
                LabeledContent("Remind at") {
                    Text(PalDate.date(current.dueAt)?.formatted(date: .abbreviated, time: .shortened) ?? current.dueAt)
                }
            }
            Text("Time zone: \(current?.timezone ?? TimeZone.current.identifier)").font(.footnote).foregroundStyle(.secondary)
            if let current {
                Text(current.status.capitalized).foregroundStyle(.secondary)
                if (current.kind ?? "reminder") != "reminder" {
                    Text("This reminder follows its plan or poll. Update that item to change it.").font(.footnote).foregroundStyle(.secondary)
                } else if current.status == "scheduled" && current.requesterID != store.userID {
                    Text("Only the person who set this reminder can change it.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("Pal sends this reminder to the group even when the app is closed.").font(.footnote).foregroundStyle(.secondary)
            if creationData != nil && !busy { Text("Retry to save this reminder.").font(.footnote).foregroundStyle(.secondary) }
            if reminder != nil && editable { Button("Cancel reminder", role: .destructive) { cancelling = true } }
            if busy { ProgressView("Saving…") }
        }.disabled(busy).navigationTitle(reminder == nil ? "New reminder" : "Reminder").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
            if editable {
                ToolbarItem(placement: .confirmationAction) {
                    Button(creationData == nil ? "Save" : "Retry") { save() }
                        .disabled(busy || (creationData == nil && !valid))
                }
            }
        }
        .onAppear { if let current { bodyText = current.body; due = PalDate.date(current.dueAt) ?? due } }
        .confirmationDialog("Cancel this reminder?", isPresented: $cancelling, titleVisibility: .visible) {
            Button("Cancel reminder", role: .destructive) {
                guard editable, let current else { return }
                mutate("reminder.cancel", ["id": .string(current.id.uuidString)])
            }
        }
    }
    private func save() {
        guard !busy, editable else { return }
        if let current {
            guard valid else { return }
            mutate("reminder.update", ["id": .string(current.id.uuidString), "body": .string(bodyText.trimmingCharacters(in: .whitespacesAndNewlines)),
                "due_at": .string(PalDate.iso(due)), "timezone": .string(current.timezone)])
        } else {
            if creationData == nil {
                guard valid else { return }
                creationData = ["body": .string(bodyText.trimmingCharacters(in: .whitespacesAndNewlines)), "due_at": .string(PalDate.iso(due)),
                    "timezone": .string(TimeZone.current.identifier), "source_key": .string(sourceKey)]
            }
            guard let creationData else { return }
            mutate("reminder.create", creationData)
        }
    }
    private func mutate(_ action: String, _ data: [String: JSONValue]) {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.mutate(group, action: action, data: data); dismiss() }
            catch { store.report(error) }
        }
    }
}
