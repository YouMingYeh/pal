import SwiftUI
import AuthenticationServices

struct RootView: View {
    @EnvironmentObject private var store: PalStore
    var body: some View {
        Group { if store.isSignedIn { GroupsView() } else { LoginView() } }
            .tint(.blue)
            .onOpenURL { store.handleURL($0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { if let url = $0.webpageURL { store.handleURL(url) } }
            .task(id: store.userID) {
                guard store.isSignedIn else { return }
                do { try await store.loadProfile(); try await store.loadGroups(); await store.acceptPendingInvite(); await store.acceptPendingNotification()
                    if store.profile?.notificationPreferences?.enabled != false, let token = UserDefaults.standard.string(forKey: "PalDeviceToken") { try await store.registerDevice(token: token) }
                } catch is CancellationError {} catch { store.error = error.localizedDescription }
            }
            .onReceive(NotificationCenter.default.publisher(for: .palDeviceToken)) { event in
                if let token = event.object as? String, store.isSignedIn, store.profile?.notificationPreferences?.enabled != false { Task { do { try await store.registerDevice(token: token) } catch { store.error = error.localizedDescription } } }
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
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 54)).foregroundStyle(.blue).accessibilityHidden(true)
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
                    store.error = error.localizedDescription
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
                        catch { store.error = error.localizedDescription }
                    }
                case .failure(let error):
                    isBusy = false
                    nonce = nil
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        store.error = error.localizedDescription
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
                                HStack { Text(group.lastMessage?.body ?? "Start a conversation").font(.subheadline).foregroundStyle(.secondary).lineLimit(2); Spacer(); if let unread = group.unreadCount, unread > 0 { Text("\(unread)").font(.caption.bold()).foregroundStyle(.white).padding(6).background(.blue, in: Circle()).accessibilityLabel("\(unread) unread messages") } }
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
    private func refresh() async { do { try await store.loadGroups() } catch is CancellationError {} catch { store.error = error.localizedDescription } }
    private func editSheet(_ title: String, field: String, value: Binding<String>, work: @escaping () async throws -> Void) -> some View {
        NavigationStack { Form { TextField(field, text: value).textInputAutocapitalization(.never); Button(title) { busy = true; Task { defer { busy = false }; do { try await work() } catch { store.error = error.localizedDescription } } }.disabled(busy || value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty); if busy { ProgressView() } }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { create = false; join = false }.disabled(busy) } } }
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
    @State private var routeCard: MessageCard?
    @State private var pollingError: String?
    @State private var lastRead: UUID?
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var pending: [OutgoingMessage] { store.outgoing.filter { item in item.groupID == group.id && item.userID == store.userID && !messages.contains(where: { $0.clientID == item.clientID }) } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 9) {
                    if messages.isEmpty { Text("Mention @Pal to ask a question or set a reminder.").font(.subheadline).foregroundStyle(.secondary).padding(.top, 28) }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || day(message.createdAt) != day(messages[index - 1].createdAt) { Text(PalDate.date(message.createdAt)?.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 10) }
                        messageRow(message).id(message.id)
                    }
                    ForEach(pending) { item in
                        HStack { Spacer(minLength: 44); VStack(alignment: .trailing, spacing: 4) { Text(item.body).padding(12).foregroundStyle(.white).background(Color.blue.opacity(0.6), in: RoundedRectangle(cornerRadius: 20)); if item.failed { Button("Not sent · Tap to retry") { Task { await store.retry(item, group: group); await refresh() } }.font(.caption).foregroundStyle(.red).frame(minHeight: 44) } else { Text("Sending…").font(.caption).foregroundStyle(.secondary) } } }.id(item.id)
                    }
                }.padding(16)
            }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 5) {
                        if let pollingError { Text(pollingError).font(.caption).foregroundStyle(.red) }
                        if let reply { HStack { Text("Reply to \(memberName(reply)): \(reply.body)").font(.caption).lineLimit(1); Spacer(); Button { self.reply = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Cancel reply") }.padding(.horizontal, 20) }
                        HStack(alignment: .bottom, spacing: 10) {
                            Menu { Button("Calendar", systemImage: "calendar") { calendar = true }; Button("Saved places", systemImage: "map") { map = true }; Button("Group details", systemImage: "person.2") { details = true } } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).foregroundStyle(.secondary).background(Color(uiColor: .secondarySystemBackground), in: Circle()) }.accessibilityLabel("Chat actions")
                            TextField("Message", text: $draft, axis: .vertical).lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 10).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                            Button { let text = draft.trimmingCharacters(in: .whitespacesAndNewlines); let replyID = reply?.id; draft = ""; reply = nil; Task { await store.queue(text, group: group, replyTo: replyID); await refresh() } } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 36)).frame(width: 44, height: 44) }.accessibilityLabel("Send message").disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.horizontal, 16).padding(.vertical, 8)
                    }.background(.bar)
                }
        }.navigationTitle(group.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Button { details = true } label: { HStack(spacing: 8) { AvatarView(name: group.name, size: 28); Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) } }.accessibilityLabel("Group details") }
                ToolbarItem(placement: .topBarTrailing) { HStack { Button { calendar = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Group calendar"); Button { map = true } label: { Image(systemName: "map") }.accessibilityLabel("Saved places") } }
            }
            .sheet(isPresented: $details) { NavigationStack { GroupDetailsView(group: group) } }
            .sheet(isPresented: $calendar) { NavigationStack { GroupCalendarView(group: group).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { calendar = false } } } } }
            .sheet(isPresented: $map) { NavigationStack { GroupMapView(group: group).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { map = false } } } } }
            .sheet(item: $remembered) { message in NavigationStack { MemoryEditor(group: group, sourceMessage: message) } }
            .sheet(item: $routeCard) { card in NavigationStack { PalCardView(group: group, card: card).padding().navigationTitle("Details").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { routeCard = nil } } } } }
            .onChange(of: store.requestedEntity) { _, card in if let card { routeCard = card; store.requestedEntity = nil } }
            .task(id: phase) {
                guard phase == .active else { return }
                if let card = store.requestedEntity { routeCard = card; store.requestedEntity = nil }
                while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: .seconds(2)) } catch { break } }
            }
    }
    private func day(_ value: String) -> Date? { PalDate.date(value).map { Calendar.current.startOfDay(for: $0) } }
    private func memberName(_ message: ChatMessage) -> String { message.role == "pal" ? "Pal" : (state.members.first { $0.userID == message.senderID }?.displayName ?? (message.senderID == store.userID ? "You" : "Member")) }
    private func messageRow(_ message: ChatMessage) -> some View {
        let mine = message.senderID == store.userID && message.role == "user"
        return HStack(alignment: .bottom, spacing: 7) {
            if mine { Spacer(minLength: 44) } else { AvatarView(name: memberName(message), url: state.members.first { $0.userID == message.senderID }?.avatarURL, size: 26) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine { Text(memberName(message)).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8) }
                if let replyID = message.replyToID, let original = messages.first(where: { $0.id == replyID }) { Text("\(memberName(original)): \(original.body)").font(.caption).lineLimit(2).foregroundStyle(.secondary).padding(8).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10)) }
                Text(message.body).textSelection(.enabled).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(mine ? Color.white : Color.primary).background(mine ? Color.blue : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                    .contextMenu { Button("Reply", systemImage: "arrowshape.turn.up.left") { reply = message }; ForEach(["❤️", "👍", "😂", "👀"], id: \.self) { emoji in Button(emoji) { Task { do { try await store.mutate(group, action: "reaction.toggle", data: ["message_id": .string(message.id.uuidString), "emoji": .string(emoji)]) } catch { store.error = error.localizedDescription } } } }; if mine { Button("Remember", systemImage: "bookmark") { remembered = message } } }
                ForEach(message.cards) { PalCardView(group: group, card: $0) }
                let reactions = state.reactions.filter { $0.messageID == message.id }
                if !reactions.isEmpty { Text(Dictionary(grouping: reactions, by: \.emoji).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: "  ")).font(.caption).padding(.horizontal, 8) }
                Text((PalDate.date(message.createdAt)?.formatted(date: .omitted, time: .shortened) ?? "") + (mine ? " · Sent" : "")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 7)
            }
            if !mine { Spacer(minLength: 28) }
        }
    }
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
        } catch is CancellationError {} catch { pollingError = error.localizedDescription }
    }
}
