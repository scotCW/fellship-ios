import Foundation
import SwiftUI

/// State for the classic MeshCore mode: public-channel chat, repeater
/// login/telemetry results, and contact favorites. Runs alongside RoomEngine
/// over the same radio session — both modes are always live.
///
/// This is an independent clean-room implementation inspired by MeshCore One
/// (github.com/Avi0n/MeshCoreOne); no code from that GPLv3 project is used.
@MainActor
final class ClassicStore: ObservableObject {
    static let channelThreadID = "mc-public-channel"

    /// Public channel (index 0) messages, oldest first.
    @Published private(set) var channelMessages: [RoomMessage] = []
    /// Radio-key-prefix (12 hex) → login state for repeaters.
    @Published private(set) var loginStates: [String: LoginState] = [:]
    /// Radio-key-prefix (12 hex) → latest telemetry readings.
    @Published private(set) var telemetry: [String: [CayenneLPP.Reading]] = [:]
    /// Rolling raw-packet log (packet monitor), newest first, capped.
    @Published private(set) var packetLog: [PacketLogRow] = []
    @Published var packetLogPaused = false
    /// Most recent route-probe result.
    @Published private(set) var lastTrace: MeshCore.TraceResult?
    @Published private(set) var traceInFlight = false
    /// Tag of the probe we're currently waiting on, so a stale reply from an
    /// earlier trace can't clobber a newer result.
    private var expectedTraceTag: UInt32?

    struct PacketLogRow: Identifiable, Equatable {
        let id = UUID()
        var receivedAt = Date()
        var entry: MeshCore.RxLogEntry
    }
    @Published var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "classicFavorites") }
    }

    enum LoginState: Equatable {
        case loggingIn
        case loggedIn
        case failed
    }

    private let store: LocalStore
    private let settings: AppSettings
    private var eventTask: Task<Void, Never>?
    private(set) var session: MeshSession?

    init(store: LocalStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        favorites = Set(UserDefaults.standard.stringArray(forKey: "classicFavorites") ?? [])
        channelMessages = (try? store.messages(threadID: Self.channelThreadID)) ?? []
    }

    func attach(session: MeshSession) {
        self.session = session
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let stream = await session.events()
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func detach() {
        session = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func handle(_ event: MeshEvent) {
        switch event {
        case .channelMessage(let message):
            // Channel 0 plaintext only — Fellship's encrypted room traffic
            // (any channel) is RoomEngine's business, not ours.
            guard message.channelIndex == 0,
                  !message.text.hasPrefix(FellshipEnvelope.roomPrefix),
                  !message.text.hasPrefix(FellshipEnvelope.directPrefix) else { return }
            appendChannel(message.text, sentAt: message.senderTimestamp, fromMe: false)
        case .loginResult(let prefix, let success):
            loginStates[prefix] = success ? .loggedIn : .failed
        case .telemetry(let prefix, let readings):
            telemetry[prefix] = readings
        case .traceCompleted(let result):
            // Ignore replies from a probe we're no longer waiting on.
            guard expectedTraceTag == nil || result.tag == expectedTraceTag else { return }
            expectedTraceTag = nil
            traceInFlight = false
            lastTrace = result
        case .packetReceived(let entry):
            guard !packetLogPaused else { return }
            packetLog.insert(PacketLogRow(entry: entry), at: 0)
            if packetLog.count > 200 {
                packetLog.removeLast(packetLog.count - 200)
            }
        default:
            break
        }
    }

    // MARK: - Public channel chat

    private func appendChannel(_ text: String, sentAt: Date, fromMe: Bool) {
        // MeshCore convention: channel senders prefix "Name: message". Only
        // honor it when it actually looks like a name — "https://…" must not
        // become a sender called "https".
        var sender = fromMe ? settings.displayName : ""
        var body = text
        if !fromMe, let range = text.range(of: ": ") {
            let candidate = String(text[..<range.lowerBound])
            if !candidate.isEmpty, candidate.count <= 32,
               !candidate.contains("\n"), !candidate.contains("/") {
                sender = candidate
                body = String(text[range.upperBound...])
            }
        }
        // Radios without a clock stamp messages near the epoch; show a
        // sane local time instead.
        let sentAt = sentAt.timeIntervalSince1970 > 1_577_836_800 ? sentAt : Date()
        let message = RoomMessage(id: UUID().uuidString,
                                  threadID: Self.channelThreadID,
                                  scope: .room,
                                  senderID: sender,
                                  senderName: sender.isEmpty ? "Unknown" : sender,
                                  text: body,
                                  sentAt: sentAt,
                                  delivery: fromMe ? .sent : .received,
                                  isFromMe: fromMe)
        try? store.saveMessage(message)
        channelMessages.append(message)
        if channelMessages.count > 500 {
            channelMessages.removeFirst(channelMessages.count - 500)
        }
    }

    /// Sends on the public channel using the stock "Name: text" convention.
    func sendChannelMessage(_ text: String) async {
        guard let session else { return }
        let name = settings.displayName.isEmpty ? "anon" : settings.displayName
        let wire = "\(name): \(text)"
        if (try? await session.sendChannelText(String(wire.prefix(150)), channelIndex: 0)) != nil {
            appendChannel(text, sentAt: Date(), fromMe: true)
        }
    }

    // MARK: - Repeater tools

    func login(contact: MeshCore.Contact, password: String) async {
        guard let session else { return }
        let prefix = contact.publicKey.prefix(6).hexEncoded
        loginStates[prefix] = .loggingIn
        do {
            try await session.login(publicKey: contact.publicKey, password: password)
        } catch {
            loginStates[prefix] = .failed
        }
    }

    func requestTelemetry(contact: MeshCore.Contact) async {
        try? await session?.requestTelemetry(publicKey: contact.publicKey)
    }

    /// Bumped when a CLI command echo is written, so terminal views refresh.
    @Published private(set) var cliRevision = 0

    func sendCommand(_ command: String, to contact: MeshCore.Contact) async {
        guard let session else { return }
        // Echo the command into the console thread so the terminal reads
        // like a terminal; the repeater's reply lands in the same thread.
        let echo = RoomMessage(id: UUID().uuidString,
                               threadID: contact.publicKey.hexEncoded,
                               scope: .direct,
                               senderID: "me",
                               senderName: settings.displayName,
                               text: "> \(command)",
                               sentAt: Date(),
                               delivery: .sent,
                               isFromMe: true)
        try? store.saveMessage(echo)
        cliRevision += 1
        _ = try? await session.sendCommand(command, to: contact.publicKey)
    }

    func consoleMessages(for contact: MeshCore.Contact) -> [RoomMessage] {
        (try? store.messages(threadID: contact.publicKey.hexEncoded)) ?? []
    }

    func removeContact(_ contact: MeshCore.Contact) async {
        try? await session?.removeContact(publicKey: contact.publicKey)
    }

    /// Route probe along a contact's current out-path.
    func tracePath(to contact: MeshCore.Contact) async {
        guard let session else { return }
        traceInFlight = true
        lastTrace = nil
        do {
            expectedTraceTag = try await session.tracePath(path: contact.outPath)
            // A route probe can go unanswered on a lossy mesh — don't spin
            // forever.
            let tag = expectedTraceTag
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.expectedTraceTag == tag else { return }
                self.expectedTraceTag = nil
                self.traceInFlight = false
            }
        } catch {
            expectedTraceTag = nil
            traceInFlight = false
        }
    }

    func clearPacketLog() {
        packetLog.removeAll()
    }

    func toggleFavorite(_ contactHex: String) {
        if favorites.contains(contactHex) {
            favorites.remove(contactHex)
        } else {
            favorites.insert(contactHex)
        }
    }
}
