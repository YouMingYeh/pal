import SwiftUI
import AuthenticationServices
import PhotosUI

/// Floating controls use native Liquid Glass when available; increased-contrast preferences keep an opaque surface.
private struct PalGlass: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: cornerRadius)).overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius)).overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
        }
    }
}

private struct ChatScrollEdges: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.scrollEdgeEffectStyle(.soft, for: .all) }
        else { content }
    }
}

/// User-driven scrolling owns its offset, including an interactive keyboard dismissal.
private struct ChatScrollInteraction: ViewModifier {
    @Binding var isInteracting: Bool
    @GestureState private var dragging = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                isInteracting = phase == .tracking || phase == .interacting || phase == .decelerating
            }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 1).updating($dragging) { _, state, _ in state = true })
                .onChange(of: dragging) { _, value in isInteracting = value }
        }
    }
}

private struct ChatNavigationSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.toolbarBackground(.hidden, for: .navigationBar) }
        else { content.toolbarBackground(.ultraThinMaterial, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar) }
    }
}

private struct PalSendButton: View {
    var disabled: Bool
    var action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            Button(action: action) { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 25, height: 35) }
                .buttonStyle(.glassProminent).tint(PalTheme.accent).foregroundStyle(PalTheme.onAccent).buttonBorderShape(.circle).disabled(disabled).accessibilityLabel("Send message")
        } else {
            Button(action: action) { Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(disabled ? Color.secondary : PalTheme.onAccent).frame(width: 44, height: 44).background(disabled ? Color(uiColor: .secondarySystemBackground) : PalTheme.accent, in: Circle()) }
                .buttonStyle(.plain).disabled(disabled).accessibilityLabel("Send message")
        }
    }
}

struct PalTypingLane: View {
    var visible: Bool
    var animated: Bool
    var onPalTap: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 40
    var body: some View {
        HStack(spacing: 6) {
            if visible {
                if let onPalTap {
                    Button(action: onPalTap) { PalMascotAvatar(emotion: "attentif", animated: animated, size: 36).contentShape(Rectangle().inset(by: -4)) }
                        .buttonStyle(.plain).accessibilityLabel("Message Pal")
                } else { PalMascotAvatar(emotion: "attentif", animated: animated, size: 36) }
                Text("Pal is typing…").font(.body).foregroundStyle(.secondary)
            }
            Spacer()
        }.frame(height: height).accessibilityElement(children: .contain).accessibilityHidden(!visible)
    }
}

enum PalChatNavigation {
    static func path(in groups: [ChatGroup], from path: [UUID]) -> [UUID]? {
        guard let id = groups.first(where: \.isDirect)?.id else { return nil }
        if let index = path.firstIndex(of: id) { return Array(path.prefix(through: index)) }
        return path + [id]
    }
}

struct RootView: View {
    @StateObject private var locationSharing = PalLocationSharing()
    @EnvironmentObject private var store: PalStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group { if store.isSignedIn { GroupsView() } else { LoginView() } }
            .tint(PalTheme.ink)
            .environment(\.palLocationSharing, locationSharing)
            .onAppear { locationSharing.configure(store: store, active: phase == .active) }
            .onChange(of: store.userID) { _, _ in locationSharing.configure(store: store, active: phase == .active) }
            .onChange(of: store.groups) { _, _ in locationSharing.configure(store: store, active: phase == .active) }
            .onOpenURL { store.handleURL($0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { if let url = $0.webpageURL { store.handleURL(url) } }
            .task(id: store.userID) {
                guard store.isSignedIn else { return }
                async let profile: Void = store.loadProfile()
                async let groups: Void = store.loadGroups()
                do { _ = try await (profile, groups) } catch { /* Each screen retains its content and offers retry. */ }
                await store.acceptPendingInvite(); await store.acceptPendingNotification()
                do {
                    if store.profile?.notificationPreferences?.enabled != false { await PalNotifications.registerIfAuthorized() }
                    if store.profile?.notificationPreferences?.enabled != false, let token = UserDefaults.standard.string(forKey: "PalDeviceToken") {
                        do { try await store.registerDevice(token: token) }
                        catch { if !PalCancellation.isCancellation(error) { store.recordPushRegistrationError(error.localizedDescription) } }
                    }
                } catch { store.report(error) }
            }
            .task(id: store.realtimeIdentity + ":" + String(describing: phase)) {
                if phase == .active, store.isSignedIn { await store.runRealtime() }
            }
            .onChange(of: phase) { _, value in
                locationSharing.configure(store: store, active: value == .active)
                if value == .active, store.isSignedIn {
                    Task {
                        if store.profile?.notificationPreferences?.enabled != false { await PalNotifications.registerIfAuthorized() }
                        if store.profile?.notificationPreferences?.enabled != false, let token = UserDefaults.standard.string(forKey: "PalDeviceToken") {
                            do { try await store.registerDevice(token: token) }
                            catch { if !PalCancellation.isCancellation(error) { store.recordPushRegistrationError(error.localizedDescription) } }
                        }
                        await store.acceptPendingNotification()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .palDeviceError)) { event in
                if let error = event.object as? String { store.recordPushRegistrationError(error) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .palDeviceToken)) { event in
                if let token = event.object as? String, store.isSignedIn, store.profile?.notificationPreferences?.enabled != false { Task { do { try await store.registerDevice(token: token) } catch { if !PalCancellation.isCancellation(error) { store.recordPushRegistrationError(error.localizedDescription) } } } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .palNotificationRoute)) { event in
                if let payload = event.object as? [AnyHashable: Any] { store.handleNotification(payload) }
            }
            .alert("Unable to continue", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
struct LoginView: View {
    @EnvironmentObject private var store: PalStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            PalMascotAvatar(size: 96).accessibilityHidden(true)
            Text("Pal").font(.largeTitle.bold())
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                isBusy = true
                do {
                    let generated = try AppleSignInNonce.make()
                    nonce = generated
                    request.nonce = AppleSignInNonce.hash(generated)
                    request.requestedScopes = [.email, .fullName]
                } catch {
                    nonce = nil
                    isBusy = false
                    store.report(error)
                }
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          let nonce else {
                        isBusy = false
                        store.error = "Apple did not return a valid sign-in. Please try again."
                        return
                    }
                    self.nonce = nil
                    Task {
                        defer { isBusy = false }
                        do {
                            try await store.authenticateApple(identityToken: credential.identityToken, nonce: nonce)
                            if let fullName = credential.fullName { try await store.saveAppleName(PersonNameComponentsFormatter().string(from: fullName)) }
                        }
                        catch { store.report(error) }
                    }
                case .failure(let error):
                    isBusy = false
                    nonce = nil
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        store.report(error)
                    }
                }
            }
            .accessibilityIdentifier("apple-sign-in")
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 14))
            .disabled(isBusy)
            .overlay(alignment: .trailing) {
                if isBusy { ProgressView().tint(colorScheme == .dark ? .black : .white).padding(.trailing, 18) }
            }
        }.padding(28).padding(.bottom, 18).background(Color(uiColor: .systemBackground))
    }
}


struct GroupsView: View {
    @EnvironmentObject private var store: PalStore
    @Environment(\.scenePhase) private var phase
    @State private var create = false
    @State private var join = false
    @State private var profile = false
    private var sharedGroups: [ChatGroup] { store.groups.filter { !$0.isDirect } }
    var body: some View {
        NavigationStack(path: $store.path) {
            Group {
                if store.groups.isEmpty {
                    if store.groupsFetch.issue != nil {
                        PalFetchStatusView(state: store.groupsFetch, hasContent: false) { Task { await refresh() } }
                            .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !store.groupsFetch.hasLoaded {
                        VStack(spacing: 14) {
                            ProgressView().controlSize(.large)
                            Text("Loading chats…").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .combine)
                    } else {
                        emptyInbox(title: "No chats yet").padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    List {
                        if store.groupsFetch.issue != nil {
                            PalFetchStatusView(state: store.groupsFetch, hasContent: true) { Task { await refresh() } }.listRowSeparator(.hidden)
                        }
                        ForEach(store.groups.filter(\.isDirect) + sharedGroups) { group in
                            NavigationLink(value: group.id) {
                                HStack(spacing: 12) {
                                    if group.isDirect { PalMascotAvatar(animated: phase == .active, size: 54) }
                                    else { AvatarView(name: group.name, url: group.avatarURL, size: 54) }
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(group.isDirect ? "Pal" : group.name).font(.headline); Spacer(); if let date = (group.lastMessage?.createdAt).flatMap(PalDate.date) { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) } }
                                        HStack { Text(group.lastMessage?.body ?? (group.isDirect ? "Your private chat" : "Start a conversation")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2); Spacer(); if let unread = group.unreadCount, unread > 0 { Text("\(unread)").font(.caption.bold()).foregroundStyle(PalTheme.onInk).padding(6).background(PalTheme.ink, in: Circle()).accessibilityLabel("\(unread) unread messages") } }
                                    }
                                }.padding(.vertical, 5)
                            }
                            .listRowSeparator(.hidden)
                        }
                        if store.groupsFetch.hasLoaded && sharedGroups.isEmpty {
                            emptyInbox(title: "No groups yet").padding(.vertical, 32).frame(maxWidth: .infinity).listRowSeparator(.hidden)
                        }
                    }.listStyle(.plain).listRowSeparator(.hidden)
                }
            }.background(Color(uiColor: .systemBackground)).navigationTitle("Pal").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationDestination(for: UUID.self) { id in if let group = store.groups.first(where: { $0.id == id }) { ChatView(group: group) } }
                .toolbar {
                    ToolbarItem(placement: .principal) { Text("Pal").font(.headline) }
                    ToolbarItem(placement: .topBarLeading) { Button { profile = true } label: { AvatarView(name: store.profile?.displayName ?? "Me", url: store.profile?.avatarURL) }.accessibilityLabel("Profile and settings") }
                    ToolbarItem(placement: .topBarTrailing) { Menu { Button("New group", systemImage: "square.and.pencil") { create = true }; Button("Join group", systemImage: "person.badge.plus") { join = true } } label: { Image(systemName: "square.and.pencil").accessibilityLabel("New chat") } }
                }
                .refreshable { await refresh() }.task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: .seconds(15)) } catch { break } }
                }
                .onChange(of: store.path) { _, path in if path.isEmpty { Task { await refresh() } } }
                .sheet(isPresented: $profile) { NavigationStack { ProfileView() } }
                .sheet(isPresented: $create) { GroupCreateView() }
                .sheet(isPresented: $join) { GroupJoinView() }
        }
    }
    private func emptyInbox(title: String) -> some View {
        VStack(spacing: 20) {
            Image("DoodleChat").renderingMode(.template).resizable().scaledToFit()
                .frame(width: 88, height: 88).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(title).font(.title3.weight(.semibold))
                Text("Create a group or join with an invite.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button { create = true } label: { Text("Create group").frame(maxWidth: .infinity, minHeight: 24) }
                    .buttonStyle(.borderedProminent).tint(PalTheme.ink).foregroundStyle(PalTheme.onInk)
                Button { join = true } label: { Text("Join group").frame(maxWidth: .infinity, minHeight: 24) }
                    .buttonStyle(.bordered).tint(PalTheme.ink)
            }.controlSize(.large).frame(maxWidth: 240)
        }.frame(maxWidth: 340)
    }
    private func refresh() async { do { try await store.loadGroups() } catch { /* Keep the inbox cache visible and offer inline retry. */ } }

}

private struct ChatContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ChatBottomOffset: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ChatTranscriptSource: Equatable {
    let messages: [ChatMessage]
    let pending: [OutgoingMessage]
    var calendar: Calendar = .current
}

/// Prepare dates once and keep one stable lazy-stack child per message.
struct ChatTranscriptRow: Identifiable {
    let item: ChatTimelineItem
    let date: Date?
    let startsDay: Bool
    let showSender: Bool
    var id: UUID { item.id }

    static func prepare(messages: [ChatMessage], pending: [OutgoingMessage], calendar: Calendar = .current) -> [Self] {
        let acknowledged = Set(messages.compactMap(\.clientID))
        let items = messages.map(ChatTimelineItem.message) + pending.filter { !acknowledged.contains($0.clientID) }.map(ChatTimelineItem.outgoing)
        let dated = items.map { (item: $0, date: PalDate.date($0.createdAt)) }
        let ordered = dated.sorted { left, right in
            let leftDate = left.date ?? .distantFuture, rightDate = right.date ?? .distantFuture
            return leftDate == rightDate ? left.item.id.uuidString < right.item.id.uuidString : leftDate < rightDate
        }
        return ordered.enumerated().map { index, value in
            let previous = index > 0 ? ordered[index - 1] : nil
            let sameDay = value.date.flatMap { date in previous?.date.map { calendar.isDate(date, inSameDayAs: $0) } } ?? false
            var showSender = true
            if sameDay, let message = value.item.message, let prior = previous?.item.message,
               message.role != "system", message.role == prior.role, message.senderID == prior.senderID,
               let date = value.date, let priorDate = previous?.date {
                showSender = !(0...180).contains(date.timeIntervalSince(priorDate))
            }
            return Self(item: value.item, date: value.date, startsDay: value.date != nil && !sameDay, showSender: showSender)
        }
    }
}

struct ChatView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @Environment(\.palLocationSharing) private var locationSharing
    @Environment(\.scenePhase) private var phase
    private var messages: [ChatMessage] { store.cachedMessages[group.id] ?? [] }
    @State private var draft = ""
    @State private var demoComposer = DemoComposerState()
    @State private var allowFocusedPrefill = false
    @FocusState private var composerFocused: Bool
    @State private var attachment: DraftAttachment?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingAudio = false
    @State private var processingPhoto = false
    @State private var photoPreparationID = UUID()
    @State private var reply: ChatMessage?
    @State private var scrollToReply: UUID?
    @State private var selectedMentions: [MessageMention: String] = [:]
    @State private var details = false
    @State private var calendar = false
    @State private var hangoutIdeas = false
    @State private var routeCard: MessageCard?
    @State private var pollingError: String?
    @State private var palChatOpening = false
    @State private var palChatIssue: String?
    @State private var lastRead: UUID?
    @State private var typingExpired = false
    @State private var atBottom = true
    @State private var userIsScrolling = false
    @State private var positionedGroup: UUID?
    @State private var bottomAnchor = UUID()
    @State private var transcriptAnchor = UUID()
    @State private var scrollPosition: UUID?
    @State private var transcriptCache: (source: ChatTranscriptSource, rows: [ChatTranscriptRow])?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var pending: [OutgoingMessage] { store.outgoing.filter { $0.groupID == group.id && $0.userID == store.userID } }
    var body: some View {
        let source = ChatTranscriptSource(messages: messages, pending: pending)
        let rows = transcriptCache.flatMap { $0.source == source ? $0.rows : nil } ?? ChatTranscriptRow.prepare(messages: source.messages, pending: source.pending, calendar: source.calendar)
        let last = rows.last?.item
        let reactions = Dictionary(grouping: state.reactions, by: \.messageID)
        return GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView {
                transcript(rows, reactions: reactions)
            }.onPreferenceChange(ChatBottomOffset.self) { bottom in
                guard bottom.isFinite, bottom > 0 else { return }
                let reachedBottom = bottom <= viewport.frame(in: .global).maxY + 60
                if atBottom != reachedBottom {
                    // Publish after the measurement pass, rather than feeding state back into that layout.
                    Task { @MainActor in atBottom = reachedBottom }
                }
            }.scrollPosition(id: $scrollPosition, anchor: .bottom).scrollDismissesKeyboard(.interactively).modifier(ChatScrollInteraction(isInteracting: $userIsScrolling)).modifier(ChatScrollEdges()).refreshable { await refresh() }
                .onChange(of: last?.id, initial: true) { _, id in
                    guard let id, !userIsScrolling else { return }
                    if positionedGroup != group.id {
                        // A bound target survives later lazy-row and container layout; an early proxy call does not.
                        positionedGroup = group.id
                        scrollPosition = bottomAnchor
                    } else if atBottom || last?.message?.senderID == store.userID || pending.last?.id == id {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: viewport.frame(in: .global)) { _, _ in
                    if atBottom, !userIsScrolling { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
                .onPreferenceChange(ChatContentHeight.self) { height in
                    if height.isFinite, height > 0, atBottom, !userIsScrolling { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .onChange(of: scrollToReply) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) }; scrollToReply = nil }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom { Button { if last != nil { withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) } } } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44).modifier(PalGlass(cornerRadius: 22)) }.buttonStyle(.plain).accessibilityLabel("Latest messages").padding(.trailing, 16).padding(.bottom, 120) }
                }
        }
        }.onChange(of: source, initial: true) { _, updated in
            transcriptCache = (updated, ChatTranscriptRow.prepare(messages: updated.messages, pending: updated.pending, calendar: updated.calendar))
        }.navigationTitle(group.isDirect ? "Pal" : group.name).navigationBarTitleDisplayMode(.inline)
            .modifier(ChatNavigationSurface())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if group.isDirect { Button(action: openPalChat) { HStack(spacing: 8) { PalMascotAvatar(animated: phase == .active, size: 36); Text("Pal").font(.title3.weight(.semibold)).foregroundStyle(.primary) } }.buttonStyle(.plain).accessibilityLabel("Message Pal") }
                    else { Button { details = true } label: { HStack(spacing: 8) { AvatarView(name: group.name, url: group.avatarURL, size: 36); Text(group.name).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) } }.buttonStyle(.plain).accessibilityLabel("Group details") }
                }
                if !group.isDirect { ToolbarItem(placement: .topBarTrailing) { Button { hangoutIdeas = true } label: { Image(systemName: "bookmark") }.accessibilityLabel("Hangout ideas") } }
                if !group.isDirect { ToolbarItem(placement: .topBarTrailing) { Button { calendar = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Group calendar") } }
                if group.isDemo { ToolbarItem(placement: .topBarTrailing) { DemoRestartControl(group: group) } }
            }
            .onChange(of: state.demo, initial: true) { _, _ in prefillNextMessage() }
            .onChange(of: pending.map(\.id)) { _, _ in prefillNextMessage() }
            .onChange(of: composerFocused) { _, focused in if !focused { prefillNextMessage() } }
            .onChange(of: draft) { _, text in if !text.isEmpty { allowFocusedPrefill = false } }
            .photosPicker(isPresented: $showingPhotos, selection: $selectedPhoto, matching: .images)
            .fullScreenCover(isPresented: $showingCamera) { CameraCapture(onCapture: { data in Task { await preparePhoto(data) } }, onError: { store.report($0) }) }
            .sheet(isPresented: $showingAudio) { AudioRecorderView(onCapture: { replaceAttachment($0) }, onError: { store.report($0) }) }
            .task(id: selectedPhoto) {
                guard let item = selectedPhoto else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PalFailure(message: "Unable to read this photo.") }
                    try Task.checkCancellation()
                    await preparePhoto(data)
                } catch { store.report(error) }
            }
            .sheet(isPresented: $details) { NavigationStack { GroupDetailsView(group: group) } }
            .navigationDestination(isPresented: $calendar) { GroupCalendarView(group: group) }
            .navigationDestination(isPresented: $hangoutIdeas) { HangoutIdeasView(group: group) }
            .sheet(item: $routeCard) { card in NavigationStack { PalCardView(group: group, card: card).padding().navigationTitle("Details").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { routeCard = nil } } } } }
            .onChange(of: store.requestedEntity) { _, card in if let card { if !["options", "choice", "availability", "question"].contains(card.type) { routeCard = card }; store.requestedEntity = nil } }
            .task(id: store.typingDeadline(in: group.id)) {
                typingExpired = false
                guard let expiry = store.typingDeadline(in: group.id) else { return }
                guard expiry > Date() else { typingExpired = true; return }
                do { try await Task.sleep(for: .seconds(expiry.timeIntervalSinceNow)); typingExpired = true } catch { }
            }
            .task(id: phase) {
                guard phase == .active else { return }
                if let card = store.requestedEntity { if !["options", "choice", "availability", "question"].contains(card.type) { routeCard = card }; store.requestedEntity = nil }
                while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: .seconds(2)) } catch { break } }
            }
    }
    private func transcript(_ rows: [ChatTranscriptRow], reactions: [UUID: [MessageReaction]]) -> some View {
        let items = rows
        return VStack(spacing: 0) {
        LazyVStack(spacing: 9) {
            if items.isEmpty, store.cachedMessages[group.id] == nil {
                if pollingError == nil { ProgressView("Loading messages…").padding(.vertical, 36) }
                else { Button("Try again") { Task { await refresh() } }.padding(.vertical, 36) }
            }
            if items.isEmpty, store.cachedMessages[group.id] != nil { VStack(spacing: 12) { Button(action: openPalChat) { PalMascotAvatar(animated: phase == .active, size: 54) }.buttonStyle(.plain).accessibilityLabel("Message Pal"); Text("No messages yet").font(.subheadline).foregroundStyle(.secondary) }.padding(.horizontal, 28).padding(.top, 36) }
            ForEach(items) { row in
                VStack(spacing: 9) {
                    if row.startsDay, let date = row.date {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 10)
                    }
                    switch row.item {
                    case .message(let message): messageRow(message, showSender: row.showSender, reactions: reactions[message.id] ?? [])
                    case .outgoing(let outgoing): pendingRow(outgoing)
                    }
                }
            }
        }.padding(16).id(transcriptAnchor)
        // This target must live outside the lazy stack so it is laid out before its rows become visible.
        Color.clear.frame(height: 1).id(bottomAnchor).background(GeometryReader { geometry in
            Color.clear.preference(key: ChatBottomOffset.self, value: geometry.frame(in: .global).maxY)
        })
        }.scrollTargetLayout().background(GeometryReader { geometry in
            Color.clear.preference(key: ChatContentHeight.self, value: geometry.size.height)
        })
    }
    private func pendingRow(_ item: OutgoingMessage) -> some View {
        HStack { Spacer(minLength: 44); VStack(alignment: .trailing, spacing: 4) {
            if let replyID = item.replyToID, let original = messages.first(where: { $0.id == replyID }) {
                replyPreview(name: memberName(original), body: original.body) { scrollToReply = original.timelineID }
            }
            if let media = item.attachment { DraftMediaPreview(draft: media, onRemove: nil) }
            if !item.body.isEmpty { Text(PalText.linked(item.body, mentions: item.mentions ?? [], members: state.members)).font(.title3).fixedSize(horizontal: false, vertical: true).tint(PalTheme.accentOnInk).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(PalTheme.onInk).background(PalTheme.ink, in: RoundedRectangle(cornerRadius: 20)) }
            if item.failed { Button("Not sent · Tap to retry") { Task { await store.retry(item, group: group); await refresh() } }.font(.caption).foregroundStyle(PalTheme.error).frame(minHeight: 44) }
        } }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            PalTypingLane(visible: !typingExpired && store.isPalTyping(in: group.id), animated: phase == .active, onPalTap: openPalChat)
                .padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let query = PalMentions.query(in: draft) {
                        if "pal".hasPrefix(query.lowercased()) { mentionButton(name: "Pal", mention: MessageMention(type: "pal"), url: nil) }
                        ForEach(PalMentions.candidates(in: state.members, query: query, excluding: store.userID)) { member in
                            mentionButton(name: member.displayName ?? "Member", mention: MessageMention(type: "user", userID: member.userID), url: member.avatarURL)
                        }
                    } else if group.isDirect {
                        quickAction("Summary", emoji: "💬", prompt: "@Pal, summarize recent conversations across all my current groups, including anything I need to respond to.")
                        quickAction("Plans", emoji: "📅", prompt: "@Pal, list recent and upcoming plans across all my current groups. Show which are proposed, confirmed or cancelled, and my attendance.")
                    } else {
                        quickAction("Plans", emoji: "📅", prompt: "@Pal, show our recent plans and what still needs a response.")
                        quickAction("Schedule", emoji: "🕒", prompt: "@Pal, show everyone's shared availability and upcoming group schedule. Keep unanswered availability visibly unknown.")
                        Button { hangoutIdeas = true } label: { HStack(spacing: 6) { Text("🍜").accessibilityHidden(true); Text("Hangout").font(.subheadline.weight(.medium)) }.padding(.horizontal, 14).frame(minHeight: 44).foregroundStyle(.primary).modifier(PalGlass(cornerRadius: 22)) }.buttonStyle(.plain).accessibilityLabel("Hangout ideas").accessibilityHint("Browse ideas saved from this chat")
                    }
                }.padding(.horizontal, 15)
            }.frame(height: 44)
            if let pollingError { HStack { Text(messages.isEmpty ? "Couldn’t load messages." : "Updates paused. Your messages are still here.").font(.caption).foregroundStyle(.secondary); Button("Retry") { Task { await refresh() } }.font(.caption.weight(.semibold)) }.padding(.horizontal, 16).accessibilityHint(pollingError) }
            if let palChatIssue { HStack { Text(palChatIssue).font(.caption).foregroundStyle(.secondary); Button("Try again", action: openPalChat).font(.caption.weight(.semibold)).disabled(palChatOpening) }.padding(.horizontal, 16) }
            if let reply { HStack { Text("Reply to \(memberName(reply)): \(reply.body)").font(.caption).lineLimit(1); Spacer(); Button { self.reply = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Cancel reply").frame(minWidth: 44, minHeight: 44) }.padding(.horizontal, 15) }
            if !group.isDirect, let locationSharing { LocationSharingStatus(group: group, sharing: locationSharing) }
            if let attachment { DraftMediaPreview(draft: attachment, onRemove: removeAttachment).padding(.horizontal, 15) }
            if processingPhoto { ProgressView("Preparing photo…").font(.caption) }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photos", systemImage: "photo") { showingPhotos = true }
                    Button("Camera", systemImage: "camera") { showingCamera = true }
                    Button("Audio", systemImage: "waveform") { showingAudio = true }
                    if !group.isDirect, let locationSharing {
                        LocationSharingMenu(group: group, sharing: locationSharing)
                    }
                } label: { Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 44, height: 44).foregroundStyle(.primary).modifier(PalGlass(cornerRadius: 22)) }.accessibilityLabel("Add attachment").disabled(processingPhoto)
                TextField(group.isDirect ? "Message Pal" : "Message", text: $draft, axis: .vertical).focused($composerFocused).font(.title3).lineLimit(1...5).padding(12).modifier(PalGlass(cornerRadius: 25)).accessibilityLabel(group.isDirect ? "Message Pal" : "Message")
                PalSendButton(disabled: processingPhoto || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil), action: sendDraft)
            }.padding(.horizontal, 15).padding(.bottom, 10)
        }
    }
    private func openPalChat() {
        guard !palChatOpening, store.userID != nil else { return }
        palChatIssue = nil
        if let path = PalChatNavigation.path(in: store.groups, from: store.path) {
            store.requestedEntity = nil
            if store.path != path { store.path = path }
            return
        }
        let userID = store.userID
        let navigation = store.path
        palChatOpening = true
        Task {
            defer { palChatOpening = false }
            do {
                try await store.loadGroups()
                guard userID == store.userID, store.path == navigation else { return }
                guard let path = PalChatNavigation.path(in: store.groups, from: store.path) else {
                    palChatIssue = "Couldn’t open your Pal chat."
                    return
                }
                store.requestedEntity = nil
                if store.path != path { store.path = path }
            } catch { if !PalCancellation.isCancellation(error), userID == store.userID, store.path == navigation { palChatIssue = "Couldn’t open your Pal chat." } }
        }
    }
    private func quickAction(_ title: String, emoji: String, prompt: String) -> some View {
        Button {
            Task { await store.queue(prompt, group: group, replyTo: nil, mentions: [MessageMention(type: "pal")]) }
        } label: {
            HStack(spacing: 6) {
                Text(emoji).accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.medium))
            }.padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(.primary).modifier(PalGlass(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityHint("Ask Pal. Your current draft stays here.")
    }

    private func mentionButton(name: String, mention: MessageMention, url: String?) -> some View {
        Button {
            draft = PalMentions.inserting(name: name, into: draft)
            selectedMentions[mention] = name
        } label: {
            HStack(spacing: 6) {
                if mention.type == "pal" { PalMascotAvatar(size: 24) } else { AvatarView(name: name, url: url, size: 24) }
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }.padding(.horizontal, 10).frame(minHeight: 44).background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        }.buttonStyle(.plain).disabled(PalMentions.retained(selectedMentions, in: draft).count >= 8 && selectedMentions[mention] == nil).accessibilityLabel("Mention " + name)
    }
    private func preparePhoto(_ data: Data) async {
        let preparationID = UUID()
        photoPreparationID = preparationID
        processingPhoto = true
        defer { if photoPreparationID == preparationID { processingPhoto = false } }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) { try AttachmentFiles.prepare(imageData: data) }.value
            if Task.isCancelled || photoPreparationID != preparationID { try? AttachmentFiles.remove(prepared); return }
            replaceAttachment(prepared)
        } catch { store.report(error) }
    }
    private func replaceAttachment(_ new: DraftAttachment) {
        if let attachment { try? AttachmentFiles.remove(attachment) }
        attachment = new
    }
    private func removeAttachment() {
        photoPreparationID = UUID(); processingPhoto = false
        if let attachment { try? AttachmentFiles.remove(attachment) }
        attachment = nil
    }
    private func memberName(_ message: ChatMessage) -> String { message.role == "pal" ? "Pal" : (state.members.first { $0.userID == message.senderID }?.displayName ?? (message.senderID == store.userID ? "You" : "Member")) }
    @ViewBuilder private func messageRow(_ message: ChatMessage, showSender: Bool, reactions: [MessageReaction]) -> some View {
        let mine = message.senderID == store.userID && message.role == "user"
        if message.role == "system" {
            if let body = message.plainBody(in: state) { Text(body).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 6) }
        } else { HStack(alignment: .bottom, spacing: 7) {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine && (showSender || message.role == "pal") {
                    if message.role == "pal" {
                        Button(action: openPalChat) { HStack(spacing: 7) { PalMascotAvatar(emotion: message.emotion, animated: phase == .active, size: 36); Text("Pal").font(.body.weight(.medium)).foregroundStyle(.secondary) }.contentShape(Rectangle().inset(by: -4)) }.buttonStyle(.plain).accessibilityLabel("Message Pal").padding(.horizontal, 4).padding(.top, 5)
                    } else if let member = state.members.first(where: { $0.userID == message.senderID }) {
                        NavigationLink { MemberDetailView(groupID: group.id, member: member) } label: {
                            HStack(spacing: 7) { AvatarView(name: memberName(message), url: member.avatarURL, size: 36); Text(memberName(message)).font(.body.weight(.medium)).foregroundStyle(.secondary) }.padding(.horizontal, 4).padding(.top, 5)
                        }.buttonStyle(.plain).accessibilityLabel("About " + memberName(message))
                    }
                }
                if let replyID = message.replyToID {
                    let original = messages.first { $0.id == replyID }
                    replyPreview(name: original.map(memberName) ?? (message.reply?.role == "pal" ? "Pal" : state.members.first { $0.userID == message.reply?.senderID }?.displayName ?? "Message"), body: original?.body ?? message.reply?.body ?? "Earlier message") { scrollToReply = original?.timelineID ?? replyID }
                }
                if let body = message.plainBody(in: state) {
                    Text(PalText.linked(body, markdown: message.role == "pal", mentions: message.mentions, members: state.members)).font(.title3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).tint(mine ? PalTheme.accentOnInk : PalTheme.accentText).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(mine ? PalTheme.onInk : PalTheme.ink).background(mine ? PalTheme.ink : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                        .contextMenu { messageMenu(message, mine: mine) }
                }
                ForEach(message.cards.filter { ["plan", "rsvp", "options", "choice", "availability", "question"].contains($0.type) && ($0.type != "question" || $0.questionText(for: group.id) != nil) }) { card in PalCardView(group: group, card: card, sourceMessageID: message.id).contextMenu { messageMenu(message, mine: mine) } }
                ForEach(message.attachments) { media in MessageAttachmentView(attachment: media, onRetry: { Task { await refresh() } }).contextMenu { messageMenu(message, mine: mine) } }
                if !reactions.isEmpty { HStack(spacing: 4) { ForEach(Array(Set(reactions.map(\.emoji))).sorted(), id: \.self) { emoji in let count = reactions.filter { $0.emoji == emoji }.count; let selected = reactions.contains { $0.emoji == emoji && $0.userID == store.userID }; Button { react(emoji, to: message) } label: { Text("\(emoji) \(count)").font(.caption).padding(.horizontal, 9).padding(.vertical, 5).background(selected ? PalTheme.ink.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: Capsule()) }.buttonStyle(.plain).frame(minHeight: 44).accessibilityLabel("\(emoji), \(count) reactions").accessibilityValue(selected ? "You reacted" : "").accessibilityHint(selected ? "Remove your reaction" : "Add your reaction") } } }
            }
            if !mine { Spacer(minLength: 28) }
        } }
    }
    private func replyPreview(name: String, body: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(PalTheme.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.caption.weight(.semibold))
                    Text(body).font(.subheadline).lineLimit(2)
                }
            }.foregroundStyle(.secondary).padding(10).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("View replied message")
    }
    @ViewBuilder private func messageMenu(_ message: ChatMessage, mine: Bool) -> some View {
        ControlGroup { ForEach(["❤️", "👍", "😂", "👀"], id: \.self) { emoji in Button { react(emoji, to: message) } label: { Text(emoji) }.accessibilityLabel("React \(emoji)") } }.controlGroupStyle(.palette)
        Button("Reply", systemImage: "arrowshape.turn.up.left") { reply = message }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
    }
    private func prefillNextMessage() {
        if let prompt = demoComposer.suggestion(for: state.demo, isDemo: group.isDemo, draft: draft,
                                                isEditing: composerFocused && !allowFocusedPrefill, hasPending: !pending.isEmpty,
                                                hasAttachment: attachment != nil || processingPhoto, hasReply: reply != nil) {
            draft = prompt
        }
    }
    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processingPhoto, !text.isEmpty || attachment != nil else { return }
        let media = attachment, replyID = reply?.id
        let submission = demoComposer.submission(for: draft, demo: state.demo, hasAttachment: media != nil, hasReply: replyID != nil)
        let body = submission?.body ?? text
        let mentions = PalMentions.retained(selectedMentions, in: body)
        draft = ""; reply = nil; attachment = nil; selectedPhoto = nil; selectedMentions = [:]
        allowFocusedPrefill = submission != nil
        Task { await store.queue(body, group: group, replyTo: replyID, attachment: media, mentions: mentions, demoStep: submission?.step, demoGeneration: submission?.generation); await refresh() }
    }
    private func react(_ emoji: String, to message: ChatMessage) { Task { do { try await store.mutate(group, action: "reaction.toggle", data: ["message_id": .string(message.id.uuidString), "emoji": .string(emoji)]) } catch { store.report(error) } } }
    private func refresh() async {
        do {
            async let history = store.messages(in: group)
            async let details: Void = store.loadState(group)
            let (loaded, _) = try await (history, details)
            try Task.checkCancellation()
            if let id = loaded.last?.id, lastRead != id, phase == .active {
                try await store.mutate(group, action: "group.read", data: ["message_id": .string(id.uuidString)])
                lastRead = id
            }
            pollingError = nil
        } catch { if !PalCancellation.isCancellation(error) { pollingError = error.localizedDescription } }
    }
}
