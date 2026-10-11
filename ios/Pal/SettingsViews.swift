import SwiftUI
import UserNotifications
import UIKit
import PhotosUI
import ImageIO

enum PalNotificationPreference {
    static func isEnabled(_ preference: Bool, authorization: UNAuthorizationStatus?) -> Bool {
        preference && (authorization == .authorized || authorization == .provisional || authorization == .ephemeral)
    }
}

enum PalAvatarImage {
    static func jpegData(from data: Data) throws -> Data {
        // Bound the encoded original before decoding a thumbnail.
        guard !data.isEmpty, data.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw PalFailure(message: "Choose a supported photo smaller than 30 MB.")
        }
        let image = UIImage(cgImage: thumbnail)
        for quality in [0.9, 0.75, 0.55] {
            if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 2 * 1024 * 1024 { return jpeg }
        }
        throw PalFailure(message: "Unable to prepare a photo smaller than 2 MB. Choose a different photo.")
    }
}

struct ProfileView: View {
    @EnvironmentObject private var store: PalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calendarLink = GoogleCalendarLink()
    @State private var name = ""
    @State private var originalName = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var avatarPreview: UIImage?
    @State private var removeAvatar = false
    @State private var photoTaskID = UUID()
    @State private var processingPhoto = false
    @State private var loadingProfile = true
    @State private var authorization: UNAuthorizationStatus?
    @State private var calendarStatus: CalendarStatus?
    @State private var calendarIssue: String?
    @State private var busy = false
    @State private var error: String?
    @State private var disconnecting = false
    @State private var discarding = false
    private var hasChanges: Bool { name.trimmingCharacters(in: .whitespacesAndNewlines) != originalName || avatarData != nil || removeAvatar }
    private var validName: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.utf16.count <= 60
    }

    var body: some View {
        let currentAvatarURL = removeAvatar ? nil : store.profile?.avatarURL
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        ZStack(alignment: .bottomTrailing) {
                            if let avatarPreview {
                                Image(uiImage: avatarPreview).resizable().scaledToFill()
                                    .frame(width: 148, height: 148).clipShape(Circle())
                            } else {
                                AvatarView(name: name, url: currentAvatarURL, size: 148)
                            }
                            Image(systemName: "photo.badge.plus").font(.title3)
                                .frame(width: 42, height: 42).background(.regularMaterial, in: Circle())
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Choose profile photo")
                    Spacer()
                }
                .padding(.vertical, 24)
                if processingPhoto { ProgressView("Preparing photo…").frame(maxWidth: .infinity) }
                if currentAvatarURL != nil || avatarData != nil || processingPhoto {
                    Button("Remove photo", role: .destructive) { removePhoto() }.frame(maxWidth: .infinity)
                }
            }.listRowBackground(Color.clear)
            Section {
                HStack {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Your name", text: $name).textContentType(.name).multilineTextAlignment(.trailing)
                }
            }
            Section("Notifications") {
                if let authorization {
                    if authorization == .denied {
                        Text("Notifications are blocked in iOS. Allow them in Settings to receive chat alerts and reminders.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { Link("Open notification settings", destination: url) }
                    } else if authorization == .notDetermined {
                        Button("Enable notifications") { updateNotifications(true) }.disabled(store.profile == nil)
                        Text("Receive chat alerts and reminders from Pal.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Toggle("Chat alerts and reminders", isOn: Binding(
                            get: { PalNotificationPreference.isEnabled(store.profile?.notificationPreferences?.enabled ?? false, authorization: authorization) },
                            set: { updateNotifications($0) }
                        )).disabled(store.profile == nil)
                    }
                } else { ProgressView("Checking notification permission…") }
                if let issue = store.pushRegistrationIssue { Text(issue).font(.footnote).foregroundStyle(.red) }
            }
            Section("Google Calendar") {
                HStack(spacing: 12) {
                    Image("GoogleCalendar").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 26, height: 26).accessibilityHidden(true)
                    if let status = calendarStatus { Text(status.connected ? "Connected" : "Not connected") }
                    else if calendarIssue != nil { Text("Unable to check connection").foregroundStyle(.secondary) }
                    else { ProgressView("Checking connection…") }
                }
                if let issue = calendarStatus?.syncError, !issue.isEmpty { Text(issue).font(.footnote).foregroundStyle(.red) }
                if let issue = calendarIssue {
                    Text(issue).font(.footnote).foregroundStyle(.red)
                    Button("Try again") { Task { await refreshCalendar() } }
                }
                if calendarStatus?.connected == true {
                    Button("Disconnect Google Calendar", role: .destructive) { disconnecting = true }
                    Text("Disconnect stops updates. Existing Google events stay in your Pal calendar.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if calendarStatus?.connected == false {
                    Button("Connect Google Calendar") { connectCalendar() }
                }
            }
            Section {
                Button("Sign out", role: .destructive) { Task { await store.logout() } }
            }
            if busy { ProgressView() }
        }
        .disabled(busy || loadingProfile)
        .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { if hasChanges { discarding = true } else { dismiss() } }.disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save profile", systemImage: "checkmark") { save() }.labelStyle(.iconOnly)
                    .disabled(busy || loadingProfile || processingPhoto || !validName || !hasChanges)
            }
        }
        .interactiveDismissDisabled(busy || hasChanges)
        .task {
            do {
                try await store.loadProfile()
                name = store.profile?.displayName ?? ""
                originalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
            loadingProfile = false
            await refreshNotificationAuthorization()
            await refreshCalendar()
        }
        .task(id: selectedPhoto) {
            guard !Task.isCancelled else { return }
            guard let item = selectedPhoto else { processingPhoto = false; return }
            let taskID = UUID()
            photoTaskID = taskID
            processingPhoto = true
            defer { if photoTaskID == taskID { processingPhoto = false } }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PalFailure(message: "Unable to read the selected photo.")
                }
                let prepared = try await Task.detached(priority: .userInitiated) { try PalAvatarImage.jpegData(from: data) }.value
                try Task.checkCancellation()
                guard selectedPhoto == item, photoTaskID == taskID else { return }
                avatarData = prepared
                avatarPreview = UIImage(data: prepared)
                removeAvatar = false
            } catch {
                if !PalCancellation.isCancellation(error) && selectedPhoto == item && photoTaskID == taskID { self.error = error.localizedDescription }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshNotificationAuthorization() } }
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
                    catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
                }
            }
        } message: { Text("Disconnect stops updates. Existing Google events stay in your Pal calendar.") }
        .confirmationDialog("Discard profile changes?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
    }

    private func save() {
        guard !busy, !processingPhoto, validName else { return }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            defer { busy = false }
            do {
                if removeAvatar {
                    _ = try await store.api("/api/profile", method: "PATCH", json: ["display_name": .string(displayName), "avatar_url": .null])
                    try await store.loadProfile()
                } else if let avatarData {
                    try await store.uploadAvatar(data: avatarData, displayName: displayName)
                } else {
                    _ = try await store.api("/api/profile", method: "PATCH", json: ["display_name": .string(displayName)])
                    try await store.loadProfile()
                }
                dismiss()
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }

    private func removePhoto() {
        guard !busy else { return }
        photoTaskID = UUID()
        selectedPhoto = nil
        processingPhoto = false
        avatarData = nil
        avatarPreview = nil
        removeAvatar = store.profile?.avatarURL != nil
    }

    private func updateNotifications(_ enabled: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let allowed = enabled ? try await PalNotifications.enable() : false
                authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                _ = try await store.api("/api/profile", method: "PATCH", json: ["notification_preferences": .object(["enabled": .bool(allowed)])])
                try await store.loadProfile()
                // The APNs callback can arrive while the preference request is still in flight.
                if let token = UserDefaults.standard.string(forKey: "PalDeviceToken") {
                    if allowed { try await store.registerDevice(token: token) }
                    else { try await store.unregisterDevice(token: token) }
                }
                if allowed { await PalNotifications.registerIfAuthorized() }
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }

    private func refreshNotificationAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if PalNotificationPreference.isEnabled(store.profile?.notificationPreferences?.enabled ?? false, authorization: authorization) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func connectCalendar() {
        busy = true
        Task {
            defer { busy = false }
            do { try await calendarLink.connect(store: store); await refreshCalendar() }
            catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }

    private func refreshCalendar() async {
        calendarIssue = nil
        do { calendarStatus = try await store.calendarStatus() }
        catch { if !PalCancellation.isCancellation(error) { calendarStatus = nil; calendarIssue = error.localizedDescription } }
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
                Toggle("Pause Pal replies", isOn: $paused)
                Text("Reminders and saved-link processing continue while replies are paused.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Proactive suggestions", isOn: $proactive)
                Button("Save group settings") { saveSettings() }
                    .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
            }.disabled(busy)
            Section("Group memory") {
                ForEach(state.memories) { memory in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.key).font(.headline)
                        Text(memory.value)
                        if let member = state.members.first(where: { $0.userID == memory.userID }) {
                            Text(member.displayName.map { "From \($0)" } ?? "From a group member").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Member unavailable").font(.caption).foregroundStyle(.secondary)
                        }
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
                    catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
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
        } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
    }

    private func saveSettings() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.mutate(group, action: "group.settings", data: ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "timezone": .string(timezone), "agent_paused": .bool(paused), "proactive_suggestions": .bool(proactive)])
                try await store.loadGroups()
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
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
                Button("Save") { save() }.disabled(busy || !ownSource || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.count > 80 || value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.count > 1000 || (kind == "availability" && expiry <= Date()))
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
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
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
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
