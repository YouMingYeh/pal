import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var calendarLink = GoogleCalendarLink()
    @State private var name = ""
    @State private var avatarURL = ""
    @State private var notifications = false
    @State private var calendarStatus: CalendarStatus?
    @State private var busy = false
    @State private var error: String?
    @State private var permissionDenied = false
    @State private var disconnecting = false

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Display name", text: $name).textContentType(.name)
                TextField("Avatar URL (optional)", text: $avatarURL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Notifications", isOn: $notifications)
                if permissionDenied {
                    Text("Notifications are disabled in iOS. Enable them in Settings, then save again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Save profile") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 60)
            }
            Section("Google Calendar") {
                if let status = calendarStatus {
                    Label(status.connected ? "Connected" : "Not connected", systemImage: status.connected ? "checkmark.circle" : "calendar")
                    if let issue = status.syncError, !issue.isEmpty { Text(issue).font(.footnote).foregroundStyle(.red) }
                }
                if calendarStatus?.connected == true {
                    Button("Disconnect Google Calendar", role: .destructive) { disconnecting = true }
                    Text("Disconnect stops updates. Existing Google events stay in your Pal calendar.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Connect Google Calendar") { connectCalendar() }
                }
                Button("Refresh connection status") { Task { await refreshCalendar() } }
            }
            Section {
                Button("Sign out", role: .destructive) { Task { await store.logout() } }
            }
            if busy { ProgressView() }
        }
        .disabled(busy)
        .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
        .task {
            do {
                try await store.loadProfile()
                name = store.profile?.displayName ?? ""
                avatarURL = store.profile?.avatarURL ?? ""
                notifications = store.profile?.notificationPreferences?.enabled ?? false
            } catch { self.error = error.localizedDescription }
            await refreshCalendar()
        }
        .alert("Unable to update profile", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Disconnect Google Calendar?", isPresented: $disconnecting, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                busy = true
                Task {
                    defer { busy = false }
                    do { try await store.disconnectCalendar(); await refreshCalendar() }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("Disconnect stops updates. Existing Google events stay in your Pal calendar.") }
    }

    private func save() {
        let avatar = avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !avatar.isEmpty {
            guard let components = URLComponents(string: avatar), ["https", "http"].contains(components.scheme),
                  components.host != nil, components.user == nil, components.password == nil, avatar.count <= 2048 else {
                error = "Use an HTTP or HTTPS avatar link without credentials."
                return
            }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let requested = notifications
                let enabled = requested ? try await PalNotifications.enable() : false
                notifications = enabled
                permissionDenied = requested && !enabled
                try await store.saveProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines), avatarURL: avatar.isEmpty ? nil : avatar, notifications: enabled)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func connectCalendar() {
        busy = true
        Task {
            defer { busy = false }
            do { try await calendarLink.connect(store: store); await refreshCalendar() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func refreshCalendar() async {
        do { calendarStatus = try await store.calendarStatus() }
        catch { self.error = error.localizedDescription }
    }
}

struct GroupDetailsView: View {
    let group: ChatGroup
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PalStore
    @State private var name = ""
    @State private var timezone = TimeZone.current.identifier
    @State private var paused = false
    @State private var proactive = false
    @State private var initialized = false
    @State private var addingMemory = false
    @State private var addingPoll = false
    @State private var deletingMemory: GroupMemory?
    @State private var editingMemory: GroupMemory?
    @State private var busy = false
    @State private var error: String?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var inviteURL: URL {
        var parts = URLComponents(string: "https://pal-jade.vercel.app/join")!
        parts.queryItems = [URLQueryItem(name: "code", value: group.inviteCode)]
        return parts.url!
    }

    var body: some View {
        Form {
            Section("Members") {
                ForEach(state.members) { member in
                    HStack {
                        AvatarView(name: member.displayName ?? "Member", url: member.avatarURL)
                        Text(member.displayName ?? "Member")
                        if member.userID == store.userID { Text("You").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ShareLink("Invite to group", item: inviteURL)
            }
            Section("Group settings") {
                TextField("Group name", text: $name)
                Picker("Time zone", selection: $timezone) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Pause Pal", isOn: $paused)
                Toggle("Proactive suggestions", isOn: $proactive)
                Button("Save group settings") { saveSettings() }
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }.disabled(busy)
            Section("Group memory") {
                ForEach(state.memories) { memory in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.key).font(.headline)
                        Text(memory.value)
                        Text(memory.kind.capitalized).font(.caption).foregroundStyle(.secondary)
                        if let expiry = memory.expiresAt.flatMap(PalDate.date) {
                            Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        if memory.userID == store.userID {
                            Button("Edit memory") { editingMemory = memory }.disabled(busy)
                            Button("Delete memory", role: .destructive) { deletingMemory = memory }.disabled(busy)
                        }
                    }
                }
                Button("Add memory", systemImage: "plus") { addingMemory = true }
            }
            Section("Polls") {
                ForEach(state.polls) { poll in
                    NavigationLink { PollCardView(group: group, pollID: poll.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(poll.question)
                            Text(poll.status.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("New poll", systemImage: "plus") { addingPoll = true }
            }
        }
        .navigationTitle("Group details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
        .task { await refresh() }.refreshable { await refresh() }
        .sheet(item: $editingMemory) { memory in NavigationStack { MemoryEditor(group: group, memory: memory) } }
        .sheet(isPresented: $addingMemory) { NavigationStack { MemoryEditor(group: group) } }
        .sheet(isPresented: $addingPoll) { NavigationStack { PollEditor(group: group) } }
        .alert("Unable to update group", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("Delete this memory?", isPresented: Binding(get: { deletingMemory != nil }, set: { if !$0 { deletingMemory = nil } }), titleVisibility: .visible) {
            Button("Delete memory", role: .destructive) {
                guard let memory = deletingMemory else { return }
                busy = true
                Task {
                    defer { busy = false; deletingMemory = nil }
                    do { try await store.mutate(group, action: "memory.delete", data: ["id": .string(memory.id.uuidString)]) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func refresh() async {
        do {
            try await store.loadState(group)
            if !initialized {
                name = state.settings?.name ?? group.name
                timezone = state.settings?.timezone ?? TimeZone.current.identifier
                paused = state.settings?.agentPaused ?? false
                proactive = state.settings?.proactiveSuggestions ?? false
                initialized = true
            }
        } catch { self.error = error.localizedDescription }
    }

    private func saveSettings() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.mutate(group, action: "group.settings", data: ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "timezone": .string(timezone), "agent_paused": .bool(paused), "proactive_suggestions": .bool(proactive)])
                try await store.loadGroups()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MemoryEditor: View {
    let group: ChatGroup
    var sourceMessage: ChatMessage? = nil
    var memory: GroupMemory? = nil
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "preference"
    @State private var key = ""
    @State private var value = ""
    @State private var expiry = Date().addingTimeInterval(86400)
    @State private var busy = false
    @State private var error: String?
    private var ownSource: Bool { sourceMessage == nil || (sourceMessage?.senderID == store.userID && sourceMessage?.role == "user") }
    var body: some View {
        Form {
            Picker("Kind", selection: $kind) {
                Text("Preference").tag("preference")
                Text("Availability").tag("availability")
            }
            TextField("Key, such as food preference", text: $key)
            TextField("What should Pal remember?", text: $value, axis: .vertical).lineLimit(3...6)
            if kind == "availability" {
                DatePicker("Expires", selection: $expiry, in: Date()...)
            }
            if let sourceMessage {
                Section("From this message") { Text(sourceMessage.body).font(.footnote).foregroundStyle(.secondary) }
                if !ownSource { Text("Save memories from your own messages.").font(.footnote).foregroundStyle(.red) }
            }
            Text("This memory is shared with the group.").font(.footnote).foregroundStyle(.secondary)
        }.disabled(busy)
        .navigationTitle("Save memory").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(busy || !ownSource || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.count > 100 || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 1000 || (kind == "availability" && expiry <= Date()))
            }
        }
        .onAppear {
            if let memory { kind = memory.kind; key = memory.key; value = memory.value; expiry = memory.expiresAt.flatMap(PalDate.date) ?? expiry }
            else if value.isEmpty { value = sourceMessage?.body ?? "" }
        }
        .alert("Unable to save memory", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() {
        busy = true
        Task {
            defer { busy = false }
            do {
                var data: [String: JSONValue] = ["kind": .string(kind), "key": .string(key.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "value": .string(value.trimmingCharacters(in: .whitespacesAndNewlines)), "expires_at": kind == "availability" ? .string(PalDate.iso(expiry)) : .null]
                if let memory { data["id"] = .string(memory.id.uuidString) }
                if let sourceMessage { data["source_message_id"] = .string(sourceMessage.id.uuidString) }
                try await store.mutate(group, action: "memory.save", data: data)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PollEditor: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "place"
    @State private var question = ""
    @State private var labels = ""
    @State private var times: [Date] = []
    @State private var nextTime = Date().addingTimeInterval(3600)
    @State private var deadline = Date().addingTimeInterval(3600)
    @State private var sourceKey = UUID().uuidString
    @State private var attempted = false
    @State private var busy = false
    @State private var error: String?
    private var placeLabels: [String] {
        labels.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private var valid: Bool {
        let count = kind == "place" ? placeLabels.count : times.count
        return !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.count <= 300
            && (2...8).contains(count) && placeLabels.allSatisfy { $0.count <= 160 } && (attempted || deadline > Date())
    }
    var body: some View {
        Form {
            Picker("Kind", selection: $kind) { Text("Place").tag("place"); Text("Time").tag("time") }
            TextField("Question", text: $question, axis: .vertical)
            if kind == "place" {
                Section("Options") {
                    TextField("One place per line", text: $labels, axis: .vertical).lineLimit(4...10)
                    Text("Add 2–8 places, one per line.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("Options") {
                    ForEach(times.indices, id: \.self) { index in
                        HStack {
                            Text(times[index].formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Button("Remove time", systemImage: "minus.circle", role: .destructive) { times.remove(at: index) }.labelStyle(.iconOnly)
                        }
                    }
                    DatePicker("Option time", selection: $nextTime, in: Date()...)
                    Button("Add time") { times.append(nextTime) }.disabled(times.count >= 8 || times.contains(nextTime))
                    Text("Add 2–8 different times.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            DatePicker("Voting ends", selection: $deadline, in: Date()...)
        }.disabled(busy || attempted)
        .navigationTitle("New poll").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) { Button(attempted ? "Retry" : "Create") { save() }.disabled(busy || !valid) }
        }
        .alert("Unable to create poll", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() {
        attempted = true
        busy = true
        Task {
            defer { busy = false }
            do {
                let options: [JSONValue]
                if kind == "place" {
                    options = placeLabels.enumerated().map { index, label in .object(["id": .string("option-\(index)"), "label": .string(label)]) }
                } else {
                    options = times.enumerated().map { index, date in .object(["id": .string("option-\(index)"), "label": .string(date.formatted(date: .abbreviated, time: .shortened)), "starts_at": .string(PalDate.iso(date))]) }
                }
                try await store.mutate(group, action: "poll.create", data: ["kind": .string(kind), "question": .string(question.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "options": .array(options), "deadline_at": .string(PalDate.iso(deadline)), "source_key": .string(sourceKey)])
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
