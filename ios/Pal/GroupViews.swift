import SwiftUI
import MapKit

struct GroupMapView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @State private var mode = 0
    @State private var searching = false
    private var places: [GroupPlace] { (store.states[group.id] ?? .empty).places }

    var body: some View {
        VStack(spacing: 0) {
            if !places.isEmpty {
                Picker("View", selection: $mode) {
                    Text("Map").tag(0)
                    Text("Saved").tag(1)
                }.pickerStyle(.segmented).padding()
            }
            if places.isEmpty {
                VStack(spacing: 16) {
                    Image("DoodlePlaces").renderingMode(.template).resizable().scaledToFit()
                        .frame(width: 100, height: 100).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Your shared places").font(.title3.weight(.semibold))
                    Text("Save a place from chat, or find one here.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Find a place") { searching = true }.buttonStyle(.borderedProminent)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mode == 0 {
                Map {
                    ForEach(places.filter { $0.latitude != nil && $0.longitude != nil && $0.status == "resolved" }) { place in
                        Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude!, longitude: place.longitude!)) {
                            NavigationLink { PlaceDetailView(group: group, place: place) } label: {
                                Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(PalTheme.ink)
                                    .background(.background, in: Circle())
                            }.accessibilityLabel(place.name)
                        }
                    }
                }.mapControls { MapCompass(); MapScaleView() }
            } else {
                List {
                    ForEach(places) { place in
                        NavigationLink { PlaceDetailView(group: group, place: place) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name).font(.headline)
                                if let address = place.address { Text(address).font(.subheadline).foregroundStyle(.secondary) }
                                if place.status != "resolved" { Label("Check this place", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }.listStyle(.plain)
            }
        }
        .navigationTitle("Map").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Add place", systemImage: "plus") { searching = true } }
        .sheet(isPresented: $searching) { NavigationStack { PlaceSearchView(group: group) } }
        .task { do { try await store.loadState(group) } catch { store.report(error) } }
    }
}

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
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if busy { ProgressView("Searching…") }
            if searched && items.isEmpty && !busy { ContentUnavailableView.search(text: query) }
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
        searchTask = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                struct Response: Decodable { let places: [SearchPlace] }
                let data = try await store.api(path)
                guard !Task.isCancelled else { return }
                items = try JSONDecoder().decode(Response.self, from: data).places
                searched = true
            } catch is CancellationError {} catch {
                if !Task.isCancelled { store.report(error) }
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
                    Map { Marker(current.name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) }.frame(height: 190)
                    Button("Directions in Maps", systemImage: "arrow.triangle.turn.up.right.diamond") {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
                        item.name = current.name
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    }
                }
                if let website = current.website, let url = URL(string: website), ["http", "https"].contains(url.scheme) {
                    Link("Website", destination: url)
                }
                if let booking = current.bookingURL, let url = URL(string: booking), ["http", "https"].contains(url.scheme) {
                    Link("Open booking website", destination: url)
                }
            }
            if current.status != "resolved" {
                Section("Confirm the right place") {
                    Text("Pal needs you to check this location before adding a pin.").font(.footnote).foregroundStyle(.secondary)
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
    @State private var month = Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var days: [Date?] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month), let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let offset = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: offset) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start) }
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
                HStack {
                    Button("Previous month", systemImage: "chevron.left") { moveMonth(-1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                    Spacer()
                    Button("Next month", systemImage: "chevron.right") { moveMonth(1) }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 8) {
                    ForEach(weekdays.indices, id: \.self) { index in Text(weekdays[index]).font(.caption).foregroundStyle(.secondary) }
                    ForEach(days.indices, id: \.self) { index in
                        if let date = days[index] {
                            let active = Calendar.current.isDate(date, inSameDayAs: selected)
                            Button { selected = date } label: {
                                VStack(spacing: 3) {
                                    Text("\(Calendar.current.component(.day, from: date))").font(.body)
                                    Circle().fill(hasEvents(date) ? (active ? PalTheme.onInk : PalTheme.ink) : .clear).frame(width: 4, height: 4)
                                }.frame(maxWidth: .infinity).padding(.vertical, 5)
                                    .foregroundStyle(active ? PalTheme.onInk : PalTheme.ink)
                                    .background(active ? PalTheme.ink : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                                .accessibilityAddTraits(active ? .isSelected : [])
                        } else { Color.clear.frame(height: 38) }
                    }
                }
            }
            Section(selected.formatted(date: .abbreviated, time: .omitted)) {
                let plans = state.plans.filter { $0.status != "cancelled" && onDay($0.startsAt) }
                let reminders = state.reminders.filter { $0.status != "cancelled" && onDay($0.dueAt) }
                if plans.isEmpty && reminders.isEmpty {
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
        .refreshable { await refresh() }.task { await refresh() }
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
    private func moveMonth(_ delta: Int) { if let date = Calendar.current.date(byAdding: .month, value: delta, to: month) { month = date } }
    private func refresh() async { do { try await store.loadState(group) } catch { store.report(error) } }
}

struct PlanDetailView: View {
    let group: ChatGroup
    let plan: GroupPlan
    @EnvironmentObject private var store: PalStore
    @State private var editing = false
    @State private var busy = false
    @State private var cancelling = false
    @State private var bookingReference = ""
    @State private var calendarDraft: AppleCalendarDraft?
    @State private var savedCalendarVersion: Int?
    private var current: GroupPlan { (store.states[group.id] ?? .empty).plans.first { $0.id == plan.id } ?? plan }
    var body: some View {
        List {
            Section {
                Text(current.title).font(.title2.bold())
                if let date = current.startsAt.flatMap(PalDate.date) { Label(date.formatted(date: .complete, time: .shortened), systemImage: "calendar") }
                Text(current.status.capitalized).foregroundStyle(.secondary)
                if let notes = current.notes, !notes.isEmpty { Text(notes) }
                if let place = (store.states[group.id] ?? .empty).places.first(where: { $0.id == current.placeID }) {
                    NavigationLink { PlaceDetailView(group: group, place: place) } label: { Label(place.name, systemImage: "mappin.and.ellipse") }
                }
            }
                if savedCalendarVersion != nil || (current.status == "confirmed" && current.attendees.contains(where: { $0.userID == store.userID && $0.status == "going" })) {
                    Section("Apple Calendar") {
                        if let savedCalendarVersion {
                            Label("Saved a Calendar copy", systemImage: "checkmark.circle")
                            if current.status == "cancelled" {
                                Text("This plan was cancelled. Remove its Calendar copy yourself.").font(.footnote).foregroundStyle(.secondary)
                            } else if !current.attendees.contains(where: { $0.userID == store.userID && $0.status == "going" }) {
                                Text("You’re no longer going. Remove its Calendar copy if you don’t need it.").font(.footnote).foregroundStyle(.secondary)
                            } else if savedCalendarVersion != (current.version ?? 1) {
                                Text("Plan changed. Update its existing copy in Calendar.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Add to Calendar", systemImage: "calendar.badge.plus", action: reviewCalendarCopy).disabled(busy)
                        }
                        Text("Changes in Pal do not update this copy.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            if current.status != "cancelled" {
                Section("Your RSVP") {
                    ForEach(["going", "maybe", "declined"], id: \.self) { status in
                        Button { action("plan.rsvp", ["status": .string(status)]) } label: {
                            HStack {
                                Text(status == "declined" ? "Can’t go" : status.capitalized)
                                Spacer()
                                if current.attendees.contains(where: { $0.userID == store.userID && $0.status == status }) { Image(systemName: "checkmark") }
                            }
                        }.disabled(busy)
                    }
                    Text("\(current.attendees.filter { $0.status == "going" }.count) going").font(.footnote).foregroundStyle(.secondary)
                }
                if current.status == "confirmed" {
                    Section("Reservation") {
                        if let place = (store.states[group.id] ?? .empty).places.first(where: { $0.id == current.placeID }) {
                            if let link = place.bookingURL, let url = URL(string: link), ["https", "http"].contains(url.scheme) {
                                Link("Book", destination: url)
                            } else if let link = place.website, let url = URL(string: link), ["https", "http"].contains(url.scheme) {
                                Link("Visit website", destination: url)
                            }
                        }
                        Text(current.bookingStatus?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Not booked")
                        if let reference = current.bookingReference { Text(reference).textSelection(.enabled) }
                        Text("After booking on the website, enter your confirmation reference.").font(.footnote).foregroundStyle(.secondary)
                        TextField("Confirmation reference (optional)", text: $bookingReference)
                        Button("Mark reservation booked") { action("plan.booking", ["status": .string("booked"), "reference": .string(bookingReference)]) }.disabled(busy)
                        Button("Reservation needed") { action("plan.booking", ["status": .string("needed")]) }.disabled(busy)
                    }
                }
                Section {
                    if current.status != "confirmed" { Button("Confirm plan") { action("plan.confirm") }.disabled(busy) }
                    Button("Edit plan") { editing = true }.disabled(busy)
                    Button("Cancel plan", role: .destructive) { cancelling = true }.disabled(busy)
                }
            }
        }.navigationTitle("Plan").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            bookingReference = current.bookingReference ?? ""
            if let userID = store.userID {
                savedCalendarVersion = AppleCalendarReceipt.savedVersion(userID: userID, planID: plan.id)
            }
        }
        .sheet(item: $calendarDraft) { draft in
            AppleCalendarEditor(draft: draft) { result in
                if store.userID == draft.userID,
                   AppleCalendarReceipt.record(action: result, userID: draft.userID, planID: draft.planID, version: draft.version) {
                    savedCalendarVersion = draft.version
                }
                calendarDraft = nil
            }
        }
        .sheet(isPresented: $editing) { NavigationStack { PlanEditor(group: group, plan: current) } }
        .confirmationDialog("Cancel this group plan?", isPresented: $cancelling, titleVisibility: .visible) {
            Button("Cancel plan", role: .destructive) { action("plan.cancel") }
        }
    }
    private func reviewCalendarCopy() {
        guard let userID = store.userID, savedCalendarVersion == nil else { return }
        do {
            calendarDraft = try AppleCalendarDraft(plan: current, group: group, state: store.states[group.id] ?? .empty, userID: userID)
        } catch { store.report(error) }
    }
    private func action(_ name: String, _ extra: [String: JSONValue] = [:]) {
        busy = true
        Task {
            defer { busy = false }
            do { try await store.mutate(group, action: name, data: extra.merging(["id": .string(plan.id.uuidString)]) { _, new in new }) }
            catch { store.report(error) }
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
            if ends <= starts { Text("The end must be after the start.").foregroundStyle(.red) }
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
                    Text("Use 2,000 characters or fewer.").font(.footnote).foregroundStyle(.red)
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
