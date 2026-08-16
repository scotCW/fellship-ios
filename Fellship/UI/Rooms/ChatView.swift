import SwiftUI

/// Chat for a room (with the zone-scope composer toggle) or a direct thread
/// (when `room` is nil).
struct ChatView: View {
    @EnvironmentObject private var engine: RoomEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    /// A geofenced room is only yours to talk in while you're actually inside
    /// it. Note this blocks only when we *know* we're outside — with no fix at
    /// all `myInside` is nil, and locking someone out on a guess would be
    /// worse than letting them speak.
    private var isOutsideRoom: Bool {
        guard let room, room.kind == .geofenced else { return false }
        return engine.myInside[room.id] == false
    }

    private var hasNoPositionForRoom: Bool {
        guard let room, room.kind == .geofenced else { return false }
        return engine.myInside[room.id] == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(messages) { message in
                            VStack(alignment: .trailing, spacing: 2) {
                                MessageBubble(message: message,
                                              room: room,
                                              onReact: room.map { room in
                                                  { emoji in
                                                      Task { await engine.toggleReaction(emoji, on: message, in: room) }
                                                  }
                                              },
                                              myMemberID: engine.myIdentityHex)
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
                        // Still land at the bottom for the new message, but
                        // without the animated glide — auto-scrolling on
                        // every incoming message is motion the user didn't
                        // ask for, so it jumps instantly with Reduce Motion on.
                        if reduceMotion {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        } else {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
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
            if isOutsideRoom {
                Label("You're outside this room's area — messages send only from inside it.",
                      systemImage: "location.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            } else if hasNoPositionForRoom {
                Label("No position yet — can't confirm you're inside this room's area.",
                      systemImage: "location.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
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
                    .disabled(isOutsideRoom)
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
                .disabled(isOutsideRoom || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var placeholder: String {
        if isOutsideRoom { return "Outside the room area" }
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
    @EnvironmentObject private var settings: AppSettings
    let message: RoomMessage
    /// Set for room messages, which support reactions. Direct/channel threads
    /// pass nil and render without the reaction affordance.
    var room: Room?
    var onReact: ((String) -> Void)?
    /// My member ID, so the picker can show which reactions are already mine.
    var myMemberID: String = ""

    @State private var showPicker = false

    /// The active theme's accent, used directly (rather than `Color.accentColor`,
    /// whose resolution against `.tint()` is ambiguous) so the bubble's text
    /// contrast can be computed against the color actually on screen.
    private var bubbleBackground: Color { settings.theme.accent }
    private var bubbleForeground: Color { bubbleBackground.accessibleForeground }

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
                                .foregroundStyle(message.isFromMe ? bubbleForeground.opacity(0.8) : .orange)
                        }
                        Text(message.text)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromMe ? bubbleBackground : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(message.isFromMe ? bubbleForeground : .primary)
                    // A custom picker rather than .contextMenu: emoji in
                    // context-menu labels render as missing-glyph boxes,
                    // which is useless for a reaction picker.
                    .onLongPressGesture {
                        guard onReact != nil else { return }
                        showPicker = true
                    }
                    // Long-press has no equivalent for VoiceOver or Voice
                    // Control — this custom action exposes the same picker
                    // as a named "React" command/rotor action instead.
                    .accessibilityAction(named: Text("React")) {
                        guard onReact != nil else { return }
                        showPicker = true
                    }
                    .popover(isPresented: $showPicker,
                             attachmentAnchor: .point(.top),
                             arrowEdge: .top) {
                        ReactionPicker(selected: message.reactions.compactMap { entry in
                            entry.value.contains(myMemberID) ? entry.key : nil
                        }) { emoji in
                            showPicker = false
                            onReact?(emoji)
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                    if !message.sortedReactions.isEmpty {
                        ReactionRow(message: message, onReact: onReact)
                    }
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

/// Horizontal row of quick reactions, shown in a popover on long-press.
/// Rendering the emoji as ordinary `Text` in a plain button is what makes
/// them actually appear — emoji inside context-menu labels do not.
private struct ReactionPicker: View {
    let selected: [String]
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RoomEngine.quickReactions, id: \.self) { emoji in
                Button {
                    onPick(emoji)
                } label: {
                    Text(emoji)
                        .font(.title2)
                        .frame(width: 40, height: 40)
                        .background(selected.contains(emoji) ? Color.accentColor.opacity(0.25) : .clear,
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("React with \(emoji)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// The little pill row of emoji reactions under a message. Tapping a pill
/// toggles your own reaction, matching how every other chat app behaves.
private struct ReactionRow: View {
    let message: RoomMessage
    var onReact: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(message.sortedReactions, id: \.emoji) { entry in
                Button {
                    onReact?(entry.emoji)
                } label: {
                    HStack(spacing: 3) {
                        Text(entry.emoji)
                        if entry.memberIDs.count > 1 {
                            Text("\(entry.memberIDs.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.tertiarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(onReact == nil)
                .accessibilityLabel(entry.memberIDs.count > 1
                                    ? "\(entry.emoji) reaction, \(entry.memberIDs.count) people. Toggle yours."
                                    : "\(entry.emoji) reaction. Toggle yours.")
            }
        }
        .font(.caption)
    }
}
