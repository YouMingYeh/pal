import SwiftUI

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

private struct LoginView: View {
    @EnvironmentObject private var store: PalStore
    @State private var email = ""
    @State private var password = ""
    @State private var isBusy = false
    @State private var signUp = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A little help. More time together.").font(.title2.bold())
                        Text("Chat with friends. Let Pal handle the plans.").foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section {
                    TextField("Email", text: $email).textContentType(.emailAddress)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(signUp ? .newPassword : .password)
                    Button {
                        isBusy = true
                        Task {
                            defer { isBusy = false }
                            do { try await store.authenticate(email: email, password: password, signUp: signUp) }
                            catch { store.error = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            Text(signUp ? "Create account" : "Sign in")
                            Spacer()
                            if isBusy { ProgressView() }
                        }
                    }.disabled(isBusy || email.isEmpty || password.count < 6)
                }
                Section {
                    Button(signUp ? "Already have an account? Sign in" : "New here? Create an account") {
                        signUp.toggle()
                        store.notice = nil
                    }.disabled(isBusy)
                    if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
                }
            }.navigationTitle("Pal")
        }
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

private struct ChatView: View {
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
                LazyVStack(spacing: 14) {
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
                        TextField("Message or @Pal…", text: $draft, axis: .vertical)
                            .disabled(sending)
                            .lineLimit(1...5).padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
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
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("Group details", systemImage: "info.circle") { showingDetails = true }
        } }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                List {
                    Section("Invite a friend") {
                        Text(group.inviteCode).font(.title3.monospaced()).textSelection(.enabled)
                        ShareLink(item: group.inviteCode) { Label("Share invite code", systemImage: "square.and.arrow.up") }
                    }
                    Section("Ask Pal") {
                        Text("@Pal search for three dinner spots in San Francisco.")
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
                    Text(message.role == "pal" ? "Pal" : message.role == "system" ? "Reminder" : "Friend")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(message.body).textSelection(.enabled).foregroundStyle(mine ? .white : .primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(mine ? Color.blue : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
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
