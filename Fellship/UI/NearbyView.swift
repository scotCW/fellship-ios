import SwiftUI

/// Direct proximity messaging (spec §5.3): talk to whoever's in mesh range,
/// no room required.
struct NearbyView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            Group {
                if engine.nearbyContacts.isEmpty && engine.directThreads().isEmpty {
                    EmptyStateView(systemImage: "dot.radiowaves.left.and.right",
                                   title: "Nobody in range yet",
                                   message: app.transportState.isConnected
                                   ? "Radios appear here when the mesh hears their adverts. Range depends on terrain, antennas and repeaters."
                                   : "Connect a radio in Settings to hear who's nearby.")
                } else {
                    list
                }
            }
            .navigationTitle("Nearby")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await engine.refreshContacts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!app.transportState.isConnected)
                    .accessibilityLabel("Refresh nearby radios")
                }
            }
        }
    }

    private var list: some View {
        List {
            let threads = engine.directThreads()
            if !threads.isEmpty {
                Section("Conversations") {
                    ForEach(threads, id: \.peerHex) { thread in
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

            if !engine.nearbyContacts.isEmpty {
                Section("Heard on the mesh") {
                    ForEach(engine.nearbyContacts, id: \.publicKey) { contact in
                        let hex = contact.publicKey.hexEncoded
                        NavigationLink {
                            DirectChatScreen(peerHex: hex,
                                             peerName: contact.name.isEmpty ? "Radio \(hex.prefix(8))" : contact.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name.isEmpty ? "Radio \(hex.prefix(8))" : contact.name)
                                        .font(.headline)
                                    Text("Heard \(Format.ago(contact.lastAdvert))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "message")
                                    .foregroundStyle(.teal)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct DirectChatScreen: View {
    let peerHex: String
    let peerName: String

    var body: some View {
        ChatView(threadID: peerHex, room: nil, peerName: peerName)
            .navigationTitle(peerName)
            .navigationBarTitleDisplayMode(.inline)
    }
}
