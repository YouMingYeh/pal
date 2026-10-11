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
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 40
    var body: some View {
        HStack(spacing: 6) {
            if visible {
                PalMascotAvatar(emotion: "attentif", animated: animated, size: 32)
                Text("Pal is typing…").font(.body).foregroundStyle(.secondary)
            }
            Spacer()
        }.frame(height: height).accessibilityElement(children: .combine).accessibilityHidden(!visible)
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
    var body: some View {
        NavigationStack(path: $store.path) {
            List {
                if store.groups.isEmpty { ContentUnavailableView("No chats", systemImage: "bubble.left.and.bubble.right", description: Text("Create a group or join with an invite.")) }
                ForEach(store.groups.filter(\.isDirect) + store.groups.filter { !$0.isDirect }) { group in
                    NavigationLink(value: group.id) {
                        HStack(spacing: 12) {
                            if group.isDirect { PalMascotAvatar(size: 50) }
                            else { AvatarView(name: group.name, url: group.avatarURL, size: 50) }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(group.isDirect ? "Pal" : group.name).font(.headline); Spacer(); if let date = (group.lastMessage?.createdAt).flatMap(PalDate.date) { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) } }
                                HStack { Text(group.lastMessage?.body ?? (group.isDirect ? "Your private chat" : "Start a conversation")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2); Spacer(); if let unread = group.unreadCount, unread > 0 { Text("\(unread)").font(.caption.bold()).foregroundStyle(PalTheme.onInk).padding(6).background(PalTheme.ink, in: Circle()).accessibilityLabel("\(unread) unread messages") } }
                            }
                        }.padding(.vertical, 5)
                    }.listRowSeparator(.hidden)
                }
            }.listStyle(.plain).listRowSeparator(.hidden).navigationTitle("Pal").navigationBarTitleDisplayMode(.inline)
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
    private func refresh() async { do { try await store.loadGroups() } catch { store.report(error) } }

}

struct ChatView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @Environment(\.scenePhase) private var phase
    private var messages: [ChatMessage] { store.cachedMessages[group.id] ?? [] }
    @State private var draft = ""
    @State private var attachment: DraftAttachment?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingCamera = false
    @State private var showingAudio = false
    @State private var processingPhoto = false
    @State private var photoPreparationID = UUID()
    @State private var reply: ChatMessage?
    @State private var details = false
    @State private var calendar = false
    @State private var map = false
    @State private var routeCard: MessageCard?
    @State private var pollingError: String?
    @State private var lastRead: UUID?
    @State private var typingExpired = false
    private var state: GroupState { store.states[group.id] ?? .empty }
    private var pending: [OutgoingMessage] { store.outgoing.filter { item in item.groupID == group.id && item.userID == store.userID && !messages.contains(where: { $0.clientID == item.clientID }) } }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcript
            }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively).modifier(ChatScrollEdges())
                .onChange(of: timeline.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }.navigationTitle(group.isDirect ? "Pal" : group.name).navigationBarTitleDisplayMode(.inline)
            .modifier(ChatNavigationSurface())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if group.isDirect { HStack(spacing: 8) { PalMascotAvatar(size: 32); Text("Pal").font(.title3.weight(.semibold)) } }
                    else { Button { details = true } label: { HStack(spacing: 8) { AvatarView(name: group.name, url: group.avatarURL, size: 32); Text(group.name).font(.title3.weight(.semibold)).foregroundStyle(.primary).lineLimit(1); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) } }.buttonStyle(.plain).accessibilityLabel("Group details") }
                }
                if !group.isDirect { ToolbarItem(placement: .topBarTrailing) { HStack { Button { calendar = true } label: { Image(systemName: "calendar") }.accessibilityLabel("Group calendar"); Button { map = true } label: { Image(systemName: "map") }.accessibilityLabel("Saved places") } } }
            }
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
            .navigationDestination(isPresented: $map) { GroupMapView(group: group) }
            .sheet(item: $routeCard) { card in NavigationStack { PalCardView(group: group, card: card).padding().navigationTitle("Details").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { routeCard = nil } } } } }
            .onChange(of: store.requestedEntity) { _, card in if let card { if !["choice", "availability"].contains(card.type) { routeCard = card }; store.requestedEntity = nil } }
            .task(id: store.typingDeadline(in: group.id)) {
                typingExpired = false
                guard let expiry = store.typingDeadline(in: group.id) else { return }
                guard expiry > Date() else { typingExpired = true; return }
                do { try await Task.sleep(for: .seconds(expiry.timeIntervalSinceNow)); typingExpired = true } catch { }
            }
            .task(id: phase) {
                guard phase == .active else { return }
                if let card = store.requestedEntity { if !["choice", "availability"].contains(card.type) { routeCard = card }; store.requestedEntity = nil }
                while !Task.isCancelled { await refresh(); do { try await Task.sleep(for: .seconds(2)) } catch { break } }
            }
    }
    private var timeline: [ChatTimelineItem] {
        (messages.map(ChatTimelineItem.message) + pending.map(ChatTimelineItem.outgoing)).sorted {
            let left = PalDate.date($0.createdAt) ?? .distantFuture
            let right = PalDate.date($1.createdAt) ?? .distantFuture
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
    }
    private var transcript: some View {
        LazyVStack(spacing: 9) {
            if timeline.isEmpty, store.cachedMessages[group.id] != nil { VStack(spacing: 12) { PalMascotAvatar(size: 54).accessibilityHidden(true); Text("No messages yet").font(.subheadline).foregroundStyle(.secondary) }.padding(.horizontal, 28).padding(.top, 36) }
            ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
                let previous = index > 0 ? timeline[index - 1] : nil
                if PalDate.date(item.createdAt) != nil, (previous?.createdAt).flatMap(day) != day(item.createdAt) {
                    Text(PalDate.date(item.createdAt)?.formatted(date: .abbreviated, time: .shortened) ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 10)
                }
                switch item {
                case .message(let message): messageRow(message, showSender: previous?.message.map { !message.follows($0) } ?? true)
                case .outgoing(let outgoing): pendingRow(outgoing)
                }
            }
        }.padding(16)
    }
    private func pendingRow(_ item: OutgoingMessage) -> some View {
        HStack { Spacer(minLength: 44); VStack(alignment: .trailing, spacing: 4) {
            if let media = item.attachment { DraftMediaPreview(draft: media, onRemove: nil) }
            if !item.body.isEmpty { Text(PalText.linked(item.body)).font(.title3).tint(PalTheme.accentOnInk).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(PalTheme.onInk).background(PalTheme.ink, in: RoundedRectangle(cornerRadius: 20)) }
            if item.failed { Button("Not sent · Tap to retry") { Task { await store.retry(item, group: group); await refresh() } }.font(.caption).foregroundStyle(.red).frame(minHeight: 44) }
        } }
    }
    private var composer: some View {
        VStack(spacing: 8) {
            PalTypingLane(visible: !typingExpired && store.isPalTyping(in: group.id), animated: phase == .active)
                .padding(.horizontal, 18)

            if let pollingError { Text(pollingError).font(.caption).foregroundStyle(.red) }
            if let reply { HStack { Text("Reply to \(memberName(reply)): \(reply.body)").font(.caption).lineLimit(1); Spacer(); Button { self.reply = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Cancel reply").frame(minWidth: 44, minHeight: 44) }.padding(.horizontal, 15) }
            if let attachment { DraftMediaPreview(draft: attachment, onRemove: removeAttachment).padding(.horizontal, 15) }
            if processingPhoto { ProgressView("Preparing photo…").font(.caption) }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button("Photos", systemImage: "photo") { showingPhotos = true }
                    Button("Camera", systemImage: "camera") { showingCamera = true }
                    Button("Audio", systemImage: "waveform") { showingAudio = true }
                } label: { Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 44, height: 44).foregroundStyle(.primary).modifier(PalGlass(cornerRadius: 22)) }.accessibilityLabel("Add attachment").disabled(processingPhoto)
                TextField(group.isDirect ? "Message Pal" : "Message", text: $draft, axis: .vertical).font(.title3).lineLimit(1...5).padding(12).modifier(PalGlass(cornerRadius: 25)).accessibilityLabel(group.isDirect ? "Message Pal" : "Message")
                PalSendButton(disabled: processingPhoto || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil), action: sendDraft)
            }.padding(.horizontal, 15).padding(.bottom, 10)
        }
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
    private func day(_ value: String) -> Date? { PalDate.date(value).map { Calendar.current.startOfDay(for: $0) } }
    private func memberName(_ message: ChatMessage) -> String { message.role == "pal" ? "Pal" : (state.members.first { $0.userID == message.senderID }?.displayName ?? (message.senderID == store.userID ? "You" : "Member")) }
    @ViewBuilder private func messageRow(_ message: ChatMessage, showSender: Bool) -> some View {
        let mine = message.senderID == store.userID && message.role == "user"
        if message.role == "system" {
            if let body = message.plainBody(in: state) { Text(body).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 6) }
        } else { HStack(alignment: .bottom, spacing: 7) {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if !mine && (showSender || message.role == "pal") { HStack(spacing: 6) { if message.role == "pal" { PalMascotAvatar(emotion: message.emotion, animated: phase == .active, size: 32).accessibilityHidden(true) } else { AvatarView(name: memberName(message), url: state.members.first { $0.userID == message.senderID }?.avatarURL, size: 32).accessibilityHidden(true) }; Text(memberName(message)).font(.body.weight(.medium)).foregroundStyle(.secondary) }.padding(.horizontal, 4).padding(.top, 5) }
                if let replyID = message.replyToID, let original = messages.first(where: { $0.id == replyID }) { Text("\(memberName(original)): \(original.body)").font(.caption).lineLimit(2).foregroundStyle(.secondary).padding(8).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10)) }
                if let body = message.plainBody(in: state) {
                    Text(PalText.linked(body, markdown: message.role == "pal")).font(.title3).textSelection(.enabled).tint(mine ? PalTheme.accentOnInk : PalTheme.accentText).padding(.horizontal, 14).padding(.vertical, 10).foregroundStyle(mine ? PalTheme.onInk : PalTheme.ink).background(mine ? PalTheme.ink : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                        .contextMenu { messageMenu(message, mine: mine) }
                }
                ForEach(message.attachments) { media in MessageAttachmentView(attachment: media, onRetry: { Task { await refresh() } }).contextMenu { messageMenu(message, mine: mine) } }
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
    }
    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !processingPhoto, !text.isEmpty || attachment != nil else { return }
        let media = attachment, replyID = reply?.id
        draft = ""; reply = nil; attachment = nil; selectedPhoto = nil
        Task { await store.queue(text, group: group, replyTo: replyID, attachment: media); await refresh() }
    }
    private func react(_ emoji: String, to message: ChatMessage) { Task { do { try await store.mutate(group, action: "reaction.toggle", data: ["message_id": .string(message.id.uuidString), "emoji": .string(emoji)]) } catch { store.report(error) } } }
    private func refresh() async {
        do {
            let loaded = try await store.messages(in: group)
            try Task.checkCancellation()
            try await store.loadState(group)
            if let id = loaded.last?.id, lastRead != id, phase == .active {
                try await store.mutate(group, action: "group.read", data: ["message_id": .string(id.uuidString)])
                lastRead = id
            }
            pollingError = nil
        } catch { if !PalCancellation.isCancellation(error) { pollingError = error.localizedDescription } }
    }
}
