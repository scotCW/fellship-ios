import SwiftUI

/// Chat for a room (with the zone-scope composer toggle) or a direct thread
/// (when `room` is nil).
struct ChatView: View {
    @EnvironmentObject private var engine: RoomEngine
    let threadID: String
    var room: Room?
    var peerName: String?

    @State private var draft = ""
    @State private var zoneOnly = false
    /// Cached so typing (which re-renders the view) doesn't hit SQLite per
    /// keystroke; reloaded only when the engine bumps its revision.
    @State private var messages: [RoomMessage] = []

    /// LoRa frames are tiny. Room messages carry encryption overhead, so
    /// their budget is tighter than plain direct messages.
    private var maxLength: Int { room != nil ? 120 : 140 }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages) { message in
                            VStack(alignment: .trailing, spacing: 2) {
                                MessageBubble(message: message)
                                if message.isFromMe, message.scope == .direct,
                                   message.delivery == .timedOut {
                                    Button {
                                        Task { await engine.retryDirectMessage(message) }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: engine.chatRevision) {
                    messages = engine.messages(threadID: threadID)
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    messages = engine.messages(threadID: threadID)
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            composer
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if room != nil && zoneOnly {
                Label("Only members currently in the zone will receive this",
                      systemImage: "scope")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if draft.count > maxLength - 20 {
                Text("\(draft.count)/\(maxLength) — mesh radio messages are short")
                    .font(.caption2)
                    .foregroundStyle(draft.count > maxLength ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 4)
            }
            HStack(spacing: 10) {
                if room != nil {
                    Button {
                        zoneOnly.toggle()
                    } label: {
                        Image(systemName: zoneOnly ? "scope" : "person.3")
                            .foregroundStyle(zoneOnly ? .orange : .secondary)
                    }
                    .accessibilityLabel(zoneOnly ? "Sending to zone only" : "Sending to whole room")
                }
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onChange(of: draft) { _, newValue in
                        if newValue.count > maxLength {
                            draft = String(newValue.prefix(maxLength))
                        }
                    }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var placeholder: String {
        if room != nil { return zoneOnly ? "Message the zone…" : "Message the room…" }
        return "Message \(peerName ?? "nearby radio")…"
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        if let room {
            Task { await engine.sendRoomMessage(room, text: text, zoneOnly: zoneOnly) }
        } else {
            Task {
                await engine.sendDirectMessage(toRadioKeyHex: threadID,
                                               peerName: peerName ?? "",
                                               text: text)
            }
        }
    }
}

struct MessageBubble: View {
    let message: RoomMessage

    var body: some View {
        if message.isSystemEvent {
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else {
            HStack {
                if message.isFromMe { Spacer(minLength: 48) }
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                    if !message.isFromMe {
                        Text(message.senderName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        if message.scope == .zone {
                            Image(systemName: "scope")
                                .font(.caption2)
                                .foregroundStyle(message.isFromMe ? .white.opacity(0.8) : .orange)
                        }
                        Text(message.text)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromMe ? Color.accentColor : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    HStack(spacing: 4) {
                        Text(message.sentAt, style: .time)
                        if message.isFromMe && !message.delivery.symbol.isEmpty {
                            Image(systemName: message.delivery.symbol)
                                .accessibilityLabel(message.delivery.label)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(message.delivery == .timedOut && message.isFromMe ? .orange : .secondary)
                }
                if !message.isFromMe { Spacer(minLength: 48) }
            }
        }
    }
}
