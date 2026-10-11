import SwiftUI
import CoreLocation

struct PalLocationPolicy {
    static func canTrack(active: Bool, hasAccount: Bool, selectedCount: Int) -> Bool { active && hasAccount && selectedCount > 0 }
    static func scopedGroups(selected: Set<UUID>, groups: [ChatGroup]) -> Set<UUID> {
        selected.intersection(Set(groups.filter { !$0.isDirect }.map(\.id)))
    }
    static func isFresh(_ location: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return (-30...300).contains(age) && location.horizontalAccuracy.isFinite && (0...10_000).contains(location.horizontalAccuracy)
            && location.coordinate.latitude.isFinite && (-90...90).contains(location.coordinate.latitude)
            && location.coordinate.longitude.isFinite && (-180...180).contains(location.coordinate.longitude)
    }
    static func shouldSend(_ location: CLLocation, last: CLLocation?, sentAt: Date?, now: Date = Date()) -> Bool {
        guard isFresh(location, now: now) else { return false }
        guard let last, let sentAt else { return true }
        return now.timeIntervalSince(sentAt) >= 60 || location.distance(from: last) >= 200
    }
}

struct PalLocationPreferences {
    let defaults: UserDefaults
    func load(owner: UUID, suffix: String = "selected") -> Set<UUID> {
        Set((defaults.stringArray(forKey: key(owner, suffix)) ?? []).compactMap(UUID.init(uuidString:)))
    }
    func save(_ groups: Set<UUID>, owner: UUID, suffix: String = "selected") {
        defaults.set(groups.map(\.uuidString).sorted(), forKey: key(owner, suffix))
    }
    private func key(_ owner: UUID, _ suffix: String) -> String { "PalLocation.\(owner.uuidString).\(suffix)" }
}

/// Only explicit group opt-ins are retained. Coordinates and tracking never survive an account change.
@MainActor final class PalLocationSharing: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var selected: Set<UUID> = []
    @Published private(set) var pendingRemoval: Set<UUID> = []
    @Published private(set) var removing: Set<UUID> = []
    @Published private(set) var confirmed: Set<UUID> = []
    @Published private(set) var issues: [UUID: String] = [:]
    @Published private(set) var permissionDenied = false
    private weak var store: PalStore?
    private var owner: UUID?
    private var generation = UUID()
    private var active = false
    private var tracking = false
    private var singleRequest = false
    private var latest: CLLocation?
    private var lastSent: [UUID: (location: CLLocation, date: Date)] = [:]
    private var uploads: [UUID: Task<Void, Never>] = [:]
    private var uploadIDs: [UUID: UUID] = [:]
    private var removals: [UUID: Task<Void, Never>] = [:]
    private var heartbeat: Task<Void, Never>?
    private var preferences = PalLocationPreferences(defaults: .standard)
    private lazy var manager: CLLocationManager = {
        let value = CLLocationManager()
        value.delegate = self
        value.desiredAccuracy = kCLLocationAccuracyHundredMeters
        value.distanceFilter = 200
        value.pausesLocationUpdatesAutomatically = true
        return value
    }()

    func configure(store: PalStore, active: Bool) {
        if owner != store.userID {
            stopDevice(); uploads.values.forEach { $0.cancel() }; removals.values.forEach { $0.cancel() }
            uploads.removeAll(); uploadIDs.removeAll(); removals.removeAll(); latest = nil; lastSent.removeAll()
            generation = UUID(); confirmed = []; issues = [:]; removing = []; permissionDenied = false
            owner = store.userID
            selected = owner.map { preferences.load(owner: $0) } ?? []
            pendingRemoval = owner.map { preferences.load(owner: $0, suffix: "removal") } ?? []
        }
        self.store = store
        self.active = active
        if store.groupsFetch.hasLoaded {
            selected = PalLocationPolicy.scopedGroups(selected: selected, groups: store.groups)
            pendingRemoval = PalLocationPolicy.scopedGroups(selected: pendingRemoval, groups: store.groups)
            confirmed = PalLocationPolicy.scopedGroups(selected: confirmed, groups: store.groups)
            persist()
        }
        reconcile()
    }

    func hasStatus(in groupID: UUID) -> Bool {
        selected.contains(groupID) || pendingRemoval.contains(groupID) || removing.contains(groupID) || issues[groupID] != nil
    }

    func share(in group: ChatGroup) {
        guard !group.isDirect, let store, owner == store.userID, owner != nil,
              store.groups.contains(where: { $0.id == group.id && !$0.isDirect }), !removing.contains(group.id) else { return }
        pendingRemoval.remove(group.id); selected.insert(group.id); issues[group.id] = nil; persist()
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        reconcile()
        if let location = latest, active, PalLocationPolicy.isFresh(location) { send(location) }
        else if active, tracking, !singleRequest {
            manager.stopUpdatingLocation(); singleRequest = true; manager.requestLocation()
        }
    }

    func stop(in group: ChatGroup) {
        guard let store, owner == store.userID, owner != nil, !removing.contains(group.id) else { return }
        let id = group.id, expected = generation
        selected.remove(id); confirmed.remove(id); pendingRemoval.insert(id); removing.insert(id); issues[id] = nil; persist()
        reconcile() // Stop device tracking immediately; retain the server-removal warning until DELETE succeeds.
        let upload = uploads[id]
        let task = Task { [weak self, weak store] in
            // Finish an already submitted POST before deleting, so it cannot recreate the stopped point afterward.
            await upload?.value
            guard let self, let store, self.generation == expected, !Task.isCancelled else { return }
            defer { if self.generation == expected { self.removing.remove(id); self.removals[id] = nil } }
            do {
                _ = try await store.api("/api/groups/\(id.uuidString)/locations", method: "DELETE")
                guard self.generation == expected, !Task.isCancelled else { return }
                self.pendingRemoval.remove(id); self.lastSent[id] = nil; self.issues[id] = nil; self.persist()
                try? await store.loadState(group)
            } catch {
                guard self.generation == expected else { return }
                if !PalCancellation.isCancellation(error) {
                    self.issues[id] = "Tracking stopped. The last shared location could not be removed; it expires within an hour."
                }
            }
        }
        removals[id] = task
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.reconcile() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.received(locations) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let isUnknown = (error as? CLError)?.code == .locationUnknown
        Task { @MainActor [weak self] in self?.failed(isUnknown: isUnknown) }
    }
    private func received(_ locations: [CLLocation]) {
        guard active, tracking, owner == store?.userID, !selected.isEmpty else { return }
        if singleRequest { singleRequest = false; manager.startUpdatingLocation() }
        guard let location = locations.last, PalLocationPolicy.isFresh(location) else { return }
        latest = location; send(location)
    }
    private func failed(isUnknown: Bool) {
        guard active, !selected.isEmpty else { return }
        if !isUnknown {
            for group in selected { issues[group] = "Location is unavailable. Try again when you have a signal." }
        }
        if singleRequest { singleRequest = false; manager.startUpdatingLocation() }
    }

    private func reconcile() {
        guard PalLocationPolicy.canTrack(active: active, hasAccount: owner != nil, selectedCount: selected.count) else { stopDevice(); return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if permissionDenied { for group in selected { issues[group] = nil } }
            permissionDenied = false
            guard !tracking else { return }
            tracking = true; manager.startUpdatingLocation()
            if let point = manager.location, PalLocationPolicy.isFresh(point) { latest = point; send(point) }
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.active, self.tracking else { return }
                    if let point = self.manager.location, PalLocationPolicy.isFresh(point) { self.latest = point; self.send(point) }
                    else if !self.singleRequest {
                        // Core Location forbids a one-shot request while continuous updates are running.
                        self.manager.stopUpdatingLocation(); self.singleRequest = true; self.manager.requestLocation()
                    }
                }
            }
        case .denied, .restricted:
            stopDevice(); permissionDenied = true
            for group in selected { issues[group] = "Allow location access in Settings to share with this group." }
        case .notDetermined:
            stopDevice()
            for group in selected { issues[group] = "Location permission is needed. Tap Retry to allow access." }
        @unknown default: stopDevice()
        }
    }

    private func stopDevice() {
        if tracking || singleRequest { manager.stopUpdatingLocation() }
        tracking = false; singleRequest = false; heartbeat?.cancel(); heartbeat = nil; latest = nil
        if !active { uploads.values.forEach { $0.cancel() }; uploads.removeAll(); uploadIDs.removeAll() }
    }
    private func persist() {
        guard let owner else { return }
        preferences.save(selected, owner: owner)
        preferences.save(pendingRemoval, owner: owner, suffix: "removal")
    }
    private func send(_ point: CLLocation) {
        guard active, let store, owner == store.userID, PalLocationPolicy.isFresh(point) else { return }
        for id in PalLocationPolicy.scopedGroups(selected: selected, groups: store.groups) where uploads[id] == nil {
            let last = lastSent[id]
            guard PalLocationPolicy.shouldSend(point, last: last?.location, sentAt: last?.date) else { continue }
            let expected = generation, uploadID = UUID()
            uploadIDs[id] = uploadID
            uploads[id] = Task { [weak self, weak store] in
                guard let self else { return }
                defer { if self.generation == expected, self.uploadIDs[id] == uploadID { self.uploads[id] = nil; self.uploadIDs[id] = nil } }
                guard let store, self.active, self.generation == expected, self.selected.contains(id), !Task.isCancelled, PalLocationPolicy.isFresh(point) else { return }
                do {
                    let data = try await store.api("/api/groups/\(id.uuidString)/locations", method: "POST", json: [
                        "latitude": .number(point.coordinate.latitude), "longitude": .number(point.coordinate.longitude), "accuracy": .number(point.horizontalAccuracy)
                    ])
                    let response = try JSONDecoder().decode(LocationResponse.self, from: data)
                    guard self.generation == expected, self.selected.contains(id), self.active, !Task.isCancelled else { return }
                    guard response.location != nil else { throw PalFailure(message: "Location was not shared.") }
                    self.lastSent[id] = (point, Date()); self.confirmed.insert(id); self.issues[id] = nil
                } catch {
                    guard self.generation == expected, self.selected.contains(id) else { return }
                    if !PalCancellation.isCancellation(error) { self.issues[id] = "Couldn’t share your location. Try again." }
                }
            }
        }
    }
    private struct LocationResponse: Decodable { let location: GroupMemberLocation? }
}

struct LocationSharingStatus: View {
    let group: ChatGroup
    @ObservedObject var sharing: PalLocationSharing
    @ViewBuilder var body: some View {
        if sharing.hasStatus(in: group.id) {
        HStack(spacing: 8) {
            if let issue = sharing.issues[group.id] {
                Text(issue).font(.caption).foregroundStyle(.secondary)
                if sharing.permissionDenied && sharing.selected.contains(group.id) {
                    Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.font(.caption.weight(.semibold))
                } else {
                    Button("Retry") { if sharing.pendingRemoval.contains(group.id) { sharing.stop(in: group) } else { sharing.share(in: group) } }.font(.caption.weight(.semibold)).disabled(sharing.removing.contains(group.id))
                }
            } else if sharing.removing.contains(group.id) {
                ProgressView(); Text("Stopping location sharing…").font(.caption).foregroundStyle(.secondary)
            } else if sharing.pendingRemoval.contains(group.id) {
                Text("Tracking stopped. Remove the last shared location.").font(.caption).foregroundStyle(.secondary)
                Button("Retry") { sharing.stop(in: group) }.font(.caption.weight(.semibold))
            } else if sharing.selected.contains(group.id) {
                Label(sharing.confirmed.contains(group.id) ? "Sharing location while Pal is open." : "Getting your location…", systemImage: "location").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 16)
        }
    }
}

struct LocationSharingMenu: View {
    let group: ChatGroup
    @ObservedObject var sharing: PalLocationSharing
    var body: some View {
        Section("Location") {
            if sharing.selected.contains(group.id) || sharing.pendingRemoval.contains(group.id) {
                Button(sharing.pendingRemoval.contains(group.id) ? "Retry stopping location" : "Stop sharing location", systemImage: "location.slash") { sharing.stop(in: group) }.disabled(sharing.removing.contains(group.id))
            } else { Button("Share location", systemImage: "location") { sharing.share(in: group) } }
        }
    }
}

private struct PalLocationSharingKey: EnvironmentKey {
    static let defaultValue: PalLocationSharing? = nil
}
extension EnvironmentValues {
    var palLocationSharing: PalLocationSharing? {
        get { self[PalLocationSharingKey.self] }
        set { self[PalLocationSharingKey.self] = newValue }
    }
}
