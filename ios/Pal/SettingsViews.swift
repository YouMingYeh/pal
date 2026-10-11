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
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var avatarData: Data?
    @State private var avatarPreview: UIImage?
    @State private var removeAvatar = false
    @State private var photoTaskID = UUID()
    @State private var processingPhoto = false
    @State private var loadingProfile = true
    @State private var profileDraftInitialized = false
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
                    Menu {
                        Button("Camera", systemImage: "camera") { selectedPhoto = nil; showingCamera = true }
                        Button("Photo Library", systemImage: "photo.on.rectangle") { selectedPhoto = nil; showingPhotoLibrary = true }
                        if currentAvatarURL != nil || avatarData != nil || processingPhoto {
                            Button("Remove Photo", systemImage: "trash", role: .destructive, action: removePhoto)
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            if let avatarPreview {
                                Image(uiImage: avatarPreview).resizable().scaledToFill()
                                    .frame(width: 148, height: 148).clipShape(Circle())
                            } else {
                                AvatarView(name: name, url: currentAvatarURL, size: 148)
                            }
                            Image(systemName: "camera.fill").font(.system(size: 15, weight: .semibold))
                                .frame(width: 32, height: 32).background(.regularMaterial, in: Circle())
                                .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 1))
                                .accessibilityHidden(true)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Edit profile photo")
                    Spacer()
                }
                .padding(.vertical, 24)
                if processingPhoto { ProgressView("Preparing photo…").frame(maxWidth: .infinity) }
            }.listRowBackground(Color.clear)
            Section {
                HStack {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Your name", text: $name).textContentType(.name).multilineTextAlignment(.trailing)
                }
            }
            if store.profileFetch.issue != nil || (store.profile == nil && loadingProfile) {
                Section { PalFetchStatusView(state: store.profileFetch, hasContent: store.profile != nil) { Task { await loadDraftProfile() } } }
            }
            Section("Notifications") {
                if let authorization {
                    if authorization == .denied {
                        Text("Notifications are blocked in iOS. Allow them in Settings to receive chat alerts and reminders.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { Link("Open notification settings", destination: url) }
                    } else if authorization == .notDetermined {
                        Button("Enable notifications") { updateNotifications(true) }.tint(PalTheme.accentText).disabled(store.profile == nil)
                        Text("Receive chat alerts and reminders from Pal.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Toggle("Chat alerts and reminders", isOn: Binding(
                            get: { PalNotificationPreference.isEnabled(store.profile?.notificationPreferences?.enabled ?? false, authorization: authorization) },
                            set: { updateNotifications($0) }
                        )).tint(PalTheme.accent).disabled(store.profile == nil)
                    }
                } else { ProgressView("Checking notification permission…") }
                if store.pushRegistrationIssue != nil {
                    Text("Notifications could not connect.").font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { updateNotifications(true) }.disabled(busy || store.profile == nil)
                }
            }
            Section("Google Calendar") {
                HStack(spacing: 12) {
                    Image("GoogleCalendar").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 26, height: 26).accessibilityHidden(true)
                    if let status = calendarStatus { Text(status.connected ? "Connected" : "Not connected") }
                    else if calendarIssue != nil { Text("Unable to check connection").foregroundStyle(.secondary) }
                    else { ProgressView("Checking connection…") }
                }
                if let issue = calendarStatus?.syncError, !issue.isEmpty { Text(issue).font(.footnote).foregroundStyle(PalTheme.error) }
                if let issue = calendarIssue {
                    Text(issue).font(.footnote).foregroundStyle(PalTheme.error)
                    Button("Try again") { Task { await refreshCalendar() } }
                }
                if calendarStatus?.connected == true {
                    Button("Disconnect Google Calendar", role: .destructive) { disconnecting = true }
                    Text("Disconnect stops updates. Existing Google events stay in your Pal calendar.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if calendarStatus?.connected == false {
                    Button("Connect Google Calendar") { connectCalendar() }.tint(PalTheme.accentText)
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
                Button("Cancel") { if hasChanges || processingPhoto { discarding = true } else { clearCommittedDraft(); dismiss() } }.disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save profile", systemImage: "checkmark") { save() }.labelStyle(.iconOnly)
                    .disabled(busy || loadingProfile || processingPhoto || !validName || !hasChanges)
            }
        }
        .interactiveDismissDisabled(busy || hasChanges || processingPhoto)
        .photosPicker(isPresented: $showingPhotoLibrary, selection: $selectedPhoto, matching: .images)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapture(onCapture: prepareCameraPhoto, onError: { error = $0.localizedDescription })
        }
        .task {
            seedProfileDraft()
            calendarStatus = store.cachedCalendarStatus
            async let profileLoad: Void = loadDraftProfile()
            async let notificationLoad: Void = refreshNotificationAuthorization()
            async let calendarLoad: Void = refreshCalendar()
            _ = await (profileLoad, notificationLoad, calendarLoad)
        }
        .task(id: selectedPhoto) {
            guard !Task.isCancelled else { return }
            guard let item = selectedPhoto else { return }
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
                    do { try await store.disconnectCalendar(); await refreshCalendar(force: true) }
                    catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
                }
            }
        } message: { Text("Disconnect stops updates. Existing Google events stay in your Pal calendar.") }
        .confirmationDialog("Discard profile changes?", isPresented: $discarding, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { clearCommittedDraft(); dismiss() }
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
                clearCommittedDraft()
                dismiss()
            } catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }

    private func prepareCameraPhoto(_ data: Data) {
        guard !busy else { return }
        let taskID = UUID()
        photoTaskID = taskID
        selectedPhoto = nil
        processingPhoto = true
        Task {
            defer { if photoTaskID == taskID { processingPhoto = false } }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { try PalAvatarImage.jpegData(from: data) }.value
                try Task.checkCancellation()
                guard photoTaskID == taskID else { return }
                avatarData = prepared
                avatarPreview = UIImage(data: prepared)
                removeAvatar = false
            } catch {
                if !PalCancellation.isCancellation(error) && photoTaskID == taskID { self.error = error.localizedDescription }
            }
        }
    }

    private func clearCommittedDraft() {
        originalName = store.profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = originalName
        photoTaskID = UUID()
        selectedPhoto = nil
        avatarData = nil
        avatarPreview = nil
        removeAvatar = false
        processingPhoto = false
        busy = false
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
            do { try await calendarLink.connect(store: store); await refreshCalendar(force: true) }
            catch { if !PalCancellation.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }

    private func seedProfileDraft() {
        guard !profileDraftInitialized, let profile = store.profile else { return }
        name = profile.displayName ?? ""
        originalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profileDraftInitialized = true
        loadingProfile = false
    }

    private func loadDraftProfile() async {
        seedProfileDraft()
        do { try await store.loadProfile(); seedProfileDraft() }
        catch { /* The fetch status keeps the cached draft and supplies retry. */ }
        loadingProfile = false
    }

    private func refreshCalendar(force: Bool = false) async {
        calendarIssue = nil
        do { calendarStatus = try await store.calendarStatus(force: force) }
        catch { if !PalCancellation.isCancellation(error) { calendarIssue = error.localizedDescription } }
    }
}

struct GroupDetailsView: View {
    let group: ChatGroup
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PalStore
    @State private var showingInvite = false
    private var state: GroupState { store.states[group.id] ?? .empty }
    var body: some View {
        Form {
            Section("Members") {
                if store.states[group.id] == nil || store.stateFetch[group.id]?.issue != nil {
                    PalFetchStatusView(state: store.stateFetch[group.id] ?? PalFetchState(), hasContent: store.states[group.id] != nil) { Task { await refresh() } }
                }
                ForEach(state.members) { member in
                    NavigationLink { MemberDetailView(groupID: group.id, member: member) } label: {
                        HStack {
                            AvatarView(name: member.displayName ?? "Member", url: member.avatarURL, size: 40)
                            Text(member.displayName ?? "Member")
                            if member.userID == store.userID { Text("You").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Button("Invite to group", systemImage: "qrcode") { showingInvite = true }
            }

        }.navigationTitle(group.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await refresh() }.refreshable { await refresh() }
            .sheet(isPresented: $showingInvite) { GroupInviteQRView(group: group) }
    }
    private func refresh() async {
        do { try await store.loadState(group) } catch { /* State status supplies retry without removing cached members. */ }
    }
}
