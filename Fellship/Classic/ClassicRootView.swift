import SwiftUI

/// The classic MeshCore experience: contacts, public channel, direct chats
/// and node tools — the workflow of a standard MeshCore companion app.
/// Independent clean-room implementation inspired by MeshCore One.
struct ClassicRootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var classic: ClassicStore

    var body: some View {
        TabView {
            ClassicChannelView()
                .tabItem { Label("Channel", systemImage: "megaphone") }
            ClassicChatsView()
                .tabItem { Label("Messages", systemImage: "message") }
            ClassicContactsView()
                .tabItem { Label("Contacts", systemImage: "person.2") }
            ClassicRadioView()
                .tabItem { Label("Radio", systemImage: "antenna.radiowaves.left.and.right") }
            ClassicAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

// MARK: - Public channel (channel 0, plaintext, everyone in radio range)

struct ClassicChannelView: View {
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var app: AppState
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if classic.channelMessages.isEmpty {
                    EmptyStateView(systemImage: "megaphone",
                                   title: "Public channel",
                                   message: "Messages here go unencrypted to every MeshCore radio in range — the mesh's town square. Say hello.")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(classic.channelMessages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .onChange(of: classic.channelMessages.count) {
                            if let last = classic.channelMessages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onAppear {
                            if let last = classic.channelMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                composer
            }
            .navigationTitle("Public channel")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message everyone in range…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onChange(of: draft) { _, newValue in
                    if newValue.count > 130 { draft = String(newValue.prefix(130)) }
                }
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await classic.sendChannelMessage(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty
                      || !app.transportState.isConnected)
            .accessibilityLabel("Send to public channel")
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
