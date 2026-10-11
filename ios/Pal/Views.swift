import SwiftUI
import AuthenticationServices

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

struct RootView: View {
    @EnvironmentObject private var store: PalStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group { if store.isSignedIn { GroupsView() } else { LoginView() } }
            .tint(PalTheme.ink)
            .onOpenURL { store.handleURL($0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { if let url = $0.webpageURL { store.handleURL(url) } }
            .task(id: store.userID) {
                guard store.isSignedIn else { return }
                do { try await store.loadProfile(); try await store.loadGroups(); await store.acceptPendingInvite(); await store.acceptPendingNotification()
                    if store.profile?.notificationPreferences?.enabled != false { await PalNotifications.registerIfAuthorized() }
                    if store.profile?.notificationPreferences?.enabled != false, let token = UserDefaults.standard.string(forKey: "PalDeviceToken") { try await store.registerDevice(token: token) }
                } catch { store.report(error) }
            }
            .onChange(of: phase) { _, value in
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
            Image("PalLogo").renderingMode(.original).resizable().scaledToFit()
                .frame(width: 96, height: 96).accessibilityHidden(true)
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
    @State private var create = false
    @State private var join = false
    @State private var profile = false
    @State private var name = ""
    @State private var code = ""
    @State private var busy = false
    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if store.groups.isEmpty { ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right", description: Text("Create a group or join with an invite.")) }
                ForEach(store.groups) { group in
                    NavigationLink(value: group.id) {
                        HStack(spacing: 12) {
                            AvatarView(name: group.name, size: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(group.name).font(.headline); Spacer(); if let date = (group.lastMessage?.createdAt).flatMap(PalDate.date) { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) } }
                                HStack { Text(group.lastMessage?.body ?? "Start a conversation").font(.subheadline).foregroundStyle(.secondary).lineLimit(2); Spacer(); if let unread = group.unreadCount, unread > 0 { Text("\(unread)").font(.caption.bold()).foregroundStyle(PalTheme.onInk).padding(6).background(PalTheme.ink, in: Circle()).accessibilityLabel("\(unread) unread messages") } }
                            }
                        }.padding(.vertical, 5)
                    }
                }
            }.listStyle(.plain).navigationTitle("Chats")
                .navigationDestination(for: UUID.self) { id in if let group = store.groups.first(where: { $0.id == id }) { ChatView(group: group) } }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { profile = true } label: { AvatarView(name: store.profile?.displayName ?? "Me", url: store.profile?.avatarURL) }.accessibilityLabel("Profile and settings") }
                    ToolbarItem(placement: .topBarTrailing) { Menu { Button("New group", systemImage: "square.and.pencil") { create = true }; Button("Join group", systemImage: "person.badge.plus") { join = true } } label: { Image(systemName: "square.and.pencil").accessibilityLabel("New chat") } }
                }
                .refreshable { await refresh() }.task { await refresh() }
                .onChange(of: store.path) { _, path in if path.isEmpty { Task { await refresh() } } }
                .sheet(isPresented: $profile) { NavigationStack { ProfileView() } }
                .sheet(isPresented: $create) { editSheet("New group", field: "Group name", value: $name) { try await store.createGroup(name: name); create = false; name = "" } }
                .sheet(isPresented: $join) { editSheet("Join group", field: "Invite code", value: $code) { try await store.joinGroup(code: code); join = false; code = "" } }
        }
    }
    private func refresh() async { do { try await store.loadGroups() } catch { store.report(error) } }
    private func editSheet(_ title: String, field: String, value: Binding<String>, work: @escaping () async throws -> Void) -> some View {
        NavigationStack { Form { TextField(field, text: value).textInputAutocapitalization(.never); Button(title) { busy = true; Task { defer { busy = false }; do { try await work() } catch { store.report(error) } } }.disabled(busy || value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); if busy { ProgressView() } }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { create = false; join = false }.disabled(busy) } } }
    }
}

struct ChatView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @Environment(\.scenePhase) private var phase
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var reply: ChatMessage?
    @State private var remembered: ChatMessage?
    @State private var details = false
    @State private var calendar = false
    @State private var map = false
    @State private var newReminder = false
    @State private var newPlan = false
    @State private var findPlace = false
    @State private var newMemory = false
    @State private var routeCard: MessageCard?
    @State private var pollingError: String?
    @State private var lastRead: UUID?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var pending: [OutgoingMessage] { store.outgoing.filter { item in item.groupID == group.id && item.userID == store.userID && !messages.contains(where: { $0.clientID == item.clientID }) } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcript
            }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively).modifier(ChatScrollEdges())
                .onChange(of: messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                .safeAreaInset(edge: .bottom) { composer }
        }.navigationTitle(group.name).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) { Button { details = true } label: { HStack(spacing: 8) { AvatarView(name: group.name, size: 28); Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) } }.buttonStyle(.plain).accessibilityLabel("Group details") }
                ToolbarItem(placement: .topBarTrailing) { HStack { Button { calendar = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Group calendar"); Button { map = true } label: { Image(systemName: "map") }.accessibilityLabel("Saved places") } }
            }
            .sheet(isPresented: $details) { NavigationStack { GroupDetailsView(group: group) } }
            .navigationDestination(isPresented: $calendar) { GroupCalendarView(group: group) }
            .navigationDestination(isPresented: $map) { GroupMapView(group: group) }
            .sheet(isPresented: $newReminder) { NavigationStack { ReminderEditor(group: group) } }
            .sheet(isPresented: $newPlan) { NavigationStack { PlanEditor(group: group) } }
            .sheet(isPresented: $findPlace) { NavigationStack { PlaceSearchView(group: group).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { findPlace = false } } } } }
            .sheet(isPresented: $newMemory) { NavigationStack { MemoryEditor(group: group) } }
            .sheet(item: $remembered) { message in NavigationStack { MemoryEditor(group: group, sourceMessage: message) } }
            .sheet(item: $routeCard) { card in NavigationStack { PalCardView(group: group, card: card).padding().navigationTitle("Details").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { routeCard = nil } } } } }
            .onChange(of: store.requestedEntity) { _, card in if let card { routeCard = card; store.requestedEntity = nil } }
            .task(id: phase) {
                guard phase == .active else { return }
                if let card = store.requestedEntity { routeCard = card; store.requestedEntity = nil }
                while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: .seconds(2)) } catch { break } }
            }
    }
    private var transcript: some View {
        LazyVStack(spacing: 9) {
            if messages.isEmpty { VStack(spacing: 12) { Image("PalLogo").renderingMode(.original).resizable().scaledToFit().frame(width: 54, height: 54).accessibilityHidden(true); Text("No messages yet").font(.subheadline).foregroundStyle(.secondary) }.padding(.horizontal, 28).padding(.top, 36) }
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                timelineRow(message, at: index)
            }
            ForEach(pending) { item in
                HStack { Spacer(minLength: 44); VStack(alignment: .trailing, spacing: 4) { Text(item.body).padding(12).foregroundStyle(PalTheme.onInk).background(PalTheme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 20)); if item.failed { Button("Not sent · Tap to retry") { Task { await store.retry(item, group: group); await refresh() } }.font(.caption).foregroundStyle(.red).frame(minHeight: 44) } else { Text("Sending…").font(.caption).foregroundStyle(.secondary) } } }.id(item.id)
            }
        }.padding(16)
    }
    private var composer: some View {
        VStack(spacing: 5) {
            if let pollingError { Text(pollingError).font(.caption).foregroundStyle(.red) }
            if let reply { HStack { Text("Reply to \(memberName(reply)): \(reply.body)").font(.caption).lineLimit(1); Spacer(); Button { self.reply = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Cancel reply") }.padding(.horizontal, 20) }
            HStack(alignment: .bottom, spacing: 10) {
                Menu { Button("Set reminder", systemImage: "bell") { newReminder = true }; Button("Make a plan", systemImage: "calendar.badge.plus") { newPlan = true }; Button("Find a place", systemImage: "mappin.and.ellipse") { findPlace = true }; Button("Save a preference", systemImage: "bookmark") { newMemory = true } } label: { Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 44, height: 44).foregroundStyle(.primary).modifier(PalGlass(cornerRadius: 22)) }.accessibilityLabel("Add to chat")
                HStack(alignment: .bottom, spacing: 0) {
                    TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 12).accessibilityLabel("Message")
                    Button { sendDraft() } label: { Image(systemName: "arrow.up").font(.body.weight(.semibold)).foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : PalTheme.onInk).frame(width: 32, height: 32).background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.clear : PalTheme.ink, in: Circle()).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Send message").disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.modifier(PalGlass(cornerRadius: 25))
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
    @ViewBuilder private func timelineRow(_ message: ChatMessage, at index: Int) -> some View {
        let previous = index > 0 ? messages[index - 1] : nil
        let newDay = previous.map { day(message.createdAt) != day($0.createdAt) } ?? true
        if newDay { Text(PalDate.date(message.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 10) }
        messageRow(message, showSender: previous.map { !message.follows($0) } ?? true).id(message.id)
    }
    private func day(_ value: String) -> Date? { PalDate.date(value).map { Calendar.current.startOfDay(for: $0) } }
    private func memberName(_ message: ChatMessage) -> String { message.role == "pal" ? "Pal" : (state.members.first { $0.userID == message.senderID }?.displayName ?? (message.senderID == store.userID ? "You" : "Member")) }
    @ViewBuilder private func messageRow(_ message: ChatMessage, showSender: Bool) -> some View {
        let mine = message.senderID == store.userID && message.role == "user"
        if message.role == "system" {
            Text(message.body).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 6)
            ForEach(message.cards) { PalCardView(group: group, card: $0) }
        } else { HStack(alignment: .bottom, spacing: 7) {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine && showSender { HStack(spacing: 5) { if message.role == "pal" { Image("PalLogo").renderingMode(.original).resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true) }; Text(memberName(message)).font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 12).padding(.top, 5) }
                if let replyID = message.replyToID, let original = messages.first(where: { $0.id == replyID }) { Text("\(memberName(original)): \(original.body)").font(.caption).lineLimit(2).foregroundStyle(.secondary).padding(8).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10)) }
                if let body = message.displayedBody(in: state) {
                    Text(PalText.linked(body)).textSelection(.enabled).tint(mine ? PalTheme.onInk : PalTheme.ink).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(mine ? PalTheme.onInk : PalTheme.ink).background(mine ? PalTheme.ink : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                        .contextMenu { messageMenu(message, mine: mine) }
                }
                ForEach(message.cards) { PalCardView(group: group, card: $0).contextMenu { messageMenu(message, mine: mine) } }
                let reactions = state.reactions.filter { $0.messageID == message.id }
                if !reactions.isEmpty { HStack(spacing: 4) { ForEach(Array(Set(reactions.map(\.emoji))).sorted(), id: \.self) { emoji in let count = reactions.filter { $0.emoji == emoji }.count; let selected = reactions.contains { $0.emoji == emoji && $0.userID == store.userID }; Button { react(emoji, to: message) } label: { Text("\(emoji) \(count)").font(.caption).padding(.horizontal, 9).padding(.vertical, 5).background(selected ? PalTheme.ink.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: Capsule()) }.buttonStyle(.plain).frame(minHeight: 44).accessibilityLabel("\(emoji), \(count) reactions").accessibilityValue(selected ? "You reacted" : "").accessibilityHint(selected ? "Remove your reaction" : "Add your reaction") } } }
            }
            if !mine { Spacer(minLength: 28) }
        } }
    }
    @ViewBuilder private func messageMenu(_ message: ChatMessage, mine: Bool) -> some View {
        ControlGroup { ForEach(["❤️", "👍", "😂", "👀"], id: \.self) { emoji in Button { react(emoji, to: message) } label: { Text(emoji) }.accessibilityLabel("React \(emoji)") } }.controlGroupStyle(.palette)
        Button("Reply", systemImage: "arrowshape.turn.up.left") { reply = message }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
        if mine { Button("Save to memory", systemImage: "bookmark") { remembered = message } }
    }
    private func sendDraft() { let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }; let replyID = reply?.id; draft = ""; reply = nil; Task { await store.queue(text, group: group, replyTo: replyID); await refresh() } }
    private func react(_ emoji: String, to message: ChatMessage) { Task { do { try await store.mutate(group, action: "reaction.toggle", data: ["message_id": .string(message.id.uuidString), "emoji": .string(emoji)]) } catch { store.report(error) } } }
    private func refresh() async {
        do {
            let loaded = try await store.messages(in: group)
            try Task.checkCancellation()
            messages = loaded
            try await store.loadState(group)
            if let id = loaded.last?.id, lastRead != id, phase == .active {
                try await store.mutate(group, action: "group.read", data: ["message_id": .string(id.uuidString)])
                lastRead = id
            }
            pollingError = nil
        } catch { if !PalCancellation.isCancellation(error) { pollingError = error.localizedDescription } }
    }
}
