import SwiftUI

/// The classic MeshCore experience: contacts, public channel, direct chats
/// and node tools — the workflow of a standard MeshCore companion app.
/// Independent clean-room implementation inspired by MeshCore One.
struct ClassicRootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var classic: ClassicStore
    /// Launch-arg override (`-classicTab 2`) for UI automation.
    @State private var selectedTab = UserDefaults.standard.integer(forKey: "classicTab")

    var body: some View {
        TabView(selection: $selectedTab) {
            ClassicMessagesView()
                .tabItem { Label("Chats", systemImage: "message") }
                .tag(0)
            ClassicNodesView()
                .tabItem { Label("Nodes", systemImage: "person.2") }
                .tag(1)
            ClassicMapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(2)
            ClassicToolsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(3)
            ClassicAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(4)
        }
    }
}

/// Channel chat and direct messages in one tab, a segment apart.
struct ClassicMessagesView: View {
    @State private var segment = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $segment) {
                Text("Channels").tag(0)
                Text("Direct").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if segment == 0 {
                ClassicChannelListView()
            } else {
                ClassicChatsView()
            }
        }
    }
}

/// Lists the public channel plus every joined `#channel`, with the controls
/// to join a new one or leave an existing one.
struct ClassicChannelListView: View {
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var app: AppState
    @State private var showJoin = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ClassicChannelView(channel: nil)
                    } label: {
                        ChannelRow(title: "Public",
                                   subtitle: "Unencrypted — every radio in range",
                                   systemImage: "megaphone",
                                   count: classic.channelMessages.count)
                    }
                }
                Section {
                    if classic.joinedChannels.isEmpty {
                        Text("No channels joined yet. Join one to talk to a group without it being public.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(classic.joinedChannels) { channel in
                        NavigationLink {
                            ClassicChannelView(channel: channel)
                        } label: {
                            ChannelRow(title: channel.displayName,
                                       subtitle: "Slot \(channel.index) · encrypted",
                                       systemImage: "number",
                                       count: classic.messages(forChannel: channel.index).count)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await classic.leaveChannel(channel) }
                            } label: {
                                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                    }
                } header: {
                    Text("Group channels")
                }
            }
            .navigationTitle("Channels")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showJoin = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!app.transportState.isConnected)
                    .accessibilityLabel("Join a channel")
                }
            }
            .sheet(isPresented: $showJoin) {
                JoinChannelSheet()
            }
        }
    }
}

private struct ChannelRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct JoinChannelSheet: View {
    @EnvironmentObject private var classic: ClassicStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var secret = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Channel name (e.g. general)", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Channel")
                } footer: {
                    Text("Everyone using the same name lands on the same channel — no key exchange needed.")
                }

                Section {
                    TextField("Optional 32-character hex key", text: $secret)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Custom key")
                } footer: {
                    Text("Leave blank to derive the key from the name. Set one only if your group already shares a specific channel key.")
                }

                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }

                Section {
                    Button {
                        join()
                    } label: {
                        if busy {
                            HStack { ProgressView(); Text("Joining…") }
                        } else {
                            Text("Join channel")
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .navigationTitle("Join a channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func join() {
        busy = true
        error = nil
        Task {
            do {
                try await classic.joinChannel(name: name, secretText: secret)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't join that channel."
            }
            busy = false
        }
    }
}

// MARK: - Channel chat (public channel 0, or a joined #channel)

struct ClassicChannelView: View {
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// nil = the public channel.
    var channel: MeshChannel?
    @State private var draft = ""
    @State private var showSendFailure = false

    private var index: UInt8 { channel?.index ?? MeshChannel.publicIndex }
    private var messages: [RoomMessage] { classic.messages(forChannel: index) }
    private var title: String { channel?.displayName ?? "Public channel" }

    var body: some View {
        Group {
            VStack(spacing: 0) {
                if showSendFailure {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Message didn't send. Restored to the composer.")
                            .font(.footnote)
                        Spacer()
                        Button {
                            showSendFailure = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                if messages.isEmpty {
                    EmptyStateView(systemImage: channel == nil ? "megaphone" : "number",
                                   title: title,
                                   message: channel == nil
                                       ? "Messages here go unencrypted to every MeshCore radio in range — the mesh's town square. Say hello."
                                       : "Encrypted to everyone holding this channel's key. Say hello.")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: messages.count) {
                            if let last = messages.last {
                                if reduceMotion {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                } else {
                                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                                }
                            }
                        }
                        .onAppear {
                            if let last = messages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                composer
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: classic.channelSendError) { _, failed in
                guard let failed else { return }
                if draft.isEmpty { draft = failed }
                showSendFailure = true
                classic.channelSendError = nil
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField(channel == nil ? "Message everyone in range…" : "Message \(title)…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onChange(of: draft) { _, newValue in
                    if newValue.count > 130 { draft = String(newValue.prefix(130)) }
                }
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await classic.sendChannelMessage(text, toChannel: index) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                      || !app.transportState.isConnected)
            .accessibilityLabel("Send to \(title)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Direct messages (same store as Fellship's Nearby — one mesh, one history)

struct ClassicChatsView: View {
    @EnvironmentObject private var engine: RoomEngine

    var body: some View {
        NavigationStack {
            Group {
                let threads = engine.directThreads()
                if threads.isEmpty {
                    EmptyStateView(systemImage: "message",
                                   title: "No conversations",
                                   message: "Direct messages with radios you've heard appear here. Start one from Contacts.")
                } else {
                    List(threads, id: \.peerHex) { thread in
                        NavigationLink {
                            DirectChatScreen(peerHex: thread.peerHex, peerName: thread.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(thread.name).font(.headline)
                                if let last = thread.last {
                                    Text("\(last.isFromMe ? "You: " : "")\(last.text)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Messages")
        }
    }
}
