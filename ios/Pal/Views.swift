import SwiftUI
import AuthenticationServices

struct RootView: View {
    @EnvironmentObject private var store: PalStore
    var body: some View {
        Group {
            if store.isSignedIn { GroupsView() } else { LoginView() }
        }
        .tint(.blue)
        .alert("Unable to continue", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
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
            VStack(alignment: .leading, spacing: 14) {
                Text("Pal").font(.largeTitle.bold())
                Text("More time\ntogether.").font(.largeTitle.weight(.semibold))
                Text("Your group chat, with a little help.\nLet Pal handle the plans.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                isBusy = true
                do {
                    let generated = try AppleSignInNonce.make()
                    nonce = generated
                    request.nonce = AppleSignInNonce.hash(generated)
                    request.requestedScopes = [.email]
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
                        do { try await store.authenticateApple(identityToken: credential.identityToken, nonce: nonce) }
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

private struct GroupsView: View {
    @EnvironmentObject private var store: PalStore
    @State private var showingCreate = false
    @State private var showingJoin = false
    @State private var groupName = ""
    @State private var inviteCode = ""
    @State private var isBusy = false
    var body: some View {
        NavigationStack {
            List {
                if store.groups.isEmpty {
                    ContentUnavailableView("Your people, in one place", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Start a group or join with an invite code."))
                        .listRowSeparator(.hidden)
                }
                ForEach(store.groups) { group in
                    NavigationLink(value: group) {
                        HStack(spacing: 14) {
                            Image(systemName: "person.2.fill").font(.title3).foregroundStyle(.blue)
                                .frame(width: 48, height: 48).background(Color.blue.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name).font(.headline)
                                Text("With Pal").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chats")
            .navigationDestination(for: ChatGroup.self) { ChatView(group: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Join group", systemImage: "person.badge.plus") { showingJoin = true }
                        Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { store.signOut() }
                    } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Account and groups") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New group", systemImage: "square.and.pencil") { showingCreate = true }
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .sheet(isPresented: $showingCreate) {
                groupSheet(title: "New group", field: "Group name", value: $groupName, action: "Create group") {
                    try await store.createGroup(name: groupName)
                    showingCreate = false
                    groupName = ""
                }
            }
            .sheet(isPresented: $showingJoin) {
                groupSheet(title: "Join group", field: "Invite code", value: $inviteCode, action: "Join group") {
                    try await store.joinGroup(code: inviteCode)
                    showingJoin = false
                    inviteCode = ""
                }
            }
        }
    }
    private func refresh() async {
        do { try await store.loadGroups() }
        catch is CancellationError {} catch { store.error = error.localizedDescription }
    }
    private func groupSheet(title: String, field: String, value: Binding<String>, action: String,
                            work: @escaping () async throws -> Void) -> some View {
        NavigationStack {
            Form {
                TextField(field, text: value).textInputAutocapitalization(.never)
                Button(action) {
                    isBusy = true
                    Task {
                        defer { isBusy = false }
                        do { try await work() } catch { store.error = error.localizedDescription }
                    }
                }.disabled(isBusy || value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isBusy { ProgressView() }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") {
                showingJoin = false
                showingCreate = false
            }.disabled(isBusy) } }
        }.presentationDetents([.medium, .large])
    }
}

struct ChatView: View {
    let group: ChatGroup
    @EnvironmentObject private var store: PalStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var clientID = UUID()
    @State private var pollingError: String?
    @State private var showingDetails = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if messages.isEmpty {
                        Text("Say hello. Mention @Pal when you need a hand.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 28)
                    }
                    ForEach(messages) { message in messageBubble(message).id(message.id) }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if let pollingError { Text(pollingError).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                    HStack(alignment: .bottom, spacing: 10) {
                        Button {
                            showingDetails = true
                        } label: {
                            Image(systemName: "plus").font(.title3)
                                .foregroundStyle(.secondary).frame(width: 44, height: 44)
                                .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("Group actions")
                        TextField("Message", text: $draft, axis: .vertical)
                            .disabled(sending)
                            .lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 22))
                            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                            .onChange(of: draft) { _, _ in if !sending { clientID = UUID() } }
                        Button(action: send) {
                            if sending { ProgressView().frame(width: 36, height: 36) }
                            else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 36)).accessibilityLabel("Send message") }
                        }.disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.horizontal, 16).padding(.vertical, 8)
                }.background(.bar)
            }
        }
        .navigationTitle(group.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showingDetails = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.fill").font(.caption)
                            .foregroundStyle(.white).frame(width: 30, height: 30)
                            .background(Color.gray, in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text("With Pal").font(.caption2).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain).accessibilityLabel("\(group.name), group details")
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                List {
                    Section("Invite a friend") {
                        Text(group.inviteCode).font(.title3.monospaced()).textSelection(.enabled)
                        ShareLink(item: group.inviteCode) { Label("Share invite code", systemImage: "square.and.arrow.up") }
                    }
                    Section("Ask Pal") {
                        Text("@Pal summarize our plan and tell us what still needs a volunteer.")
                        Text("@Pal remind us in 2 minutes to pick a restaurant.")
                        Text("Reminders are delivered to the group even while the app is closed.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.navigationTitle("Group details").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
            }.presentationDetents([.medium, .large])
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // shortcut: foreground polling for the spike; replace with Realtime when chat traffic grows.
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func messageBubble(_ message: ChatMessage) -> some View {
        let mine = message.role == "user" && message.senderID == store.userID
        return HStack(alignment: .bottom) {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 4) {
                if !mine {
                    Label(message.role == "pal" ? "Pal" : message.role == "system" ? "Reminder" : "Friend",
                          systemImage: message.role == "pal" ? "sparkle" : message.role == "system" ? "bell" : "person.fill")
                        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 12)
                }
                Text(message.body).textSelection(.enabled).foregroundStyle(mine ? .white : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(mine ? Color.blue : Color(uiColor: .secondarySystemBackground),
                                in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : 5,
                                                           bottomTrailingRadius: mine ? 5 : 18, topTrailingRadius: 18))
            }
            if !mine { Spacer(minLength: 44) }
        }.accessibilityElement(children: .combine)
    }
    private func refresh() async {
        do {
            let loaded = try await store.messages(in: group)
            guard !Task.isCancelled else { return }
            messages = loaded
            pollingError = nil
        } catch is CancellationError {} catch {
            if !Task.isCancelled { pollingError = error.localizedDescription }
        }
    }
    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !body.isEmpty else { return }
        sending = true
        let submissionID = clientID
        Task {
            defer { sending = false }
            do {
                try await store.send(body, to: group, clientID: submissionID)
                draft = ""
                clientID = UUID()
                await refresh()
            } catch { store.error = error.localizedDescription }
        }
    }
}
