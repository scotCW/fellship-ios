import Foundation

/// High-level events surfaced to the app from the mesh layer.
enum MeshEvent: Sendable {
    case stateChanged(TransportState)
    case selfInfoUpdated(MeshCore.SelfInfo)
    case channelMessage(MeshCore.ChannelMessage)
    case contactMessage(MeshCore.ContactMessage, sender: MeshCore.Contact?)
    case advertHeard(MeshCore.Contact)
    case sendConfirmed(ackCRC: UInt32, roundTripMillis: UInt32)
    case batteryUpdated(milliVolts: UInt16)
    case deviceInfoUpdated(MeshCore.DeviceInfo)
    case loginResult(senderPrefixHex: String, success: Bool)
    case statusResponse(senderPrefixHex: String, payload: Data)
    case telemetry(senderPrefixHex: String, readings: [CayenneLPP.Reading])
    case traceCompleted(MeshCore.TraceResult)
    case packetReceived(MeshCore.RxLogEntry)
}

/// Orchestrates one connected radio: serializes commands, correlates the
/// firmware's in-order responses, drains the message queue when the radio
/// signals `msgWaiting`, and republishes everything as `MeshEvent`s.
actor MeshSession {
    private let transport: MeshTransport

    private(set) var selfInfo: MeshCore.SelfInfo?
    private(set) var deviceInfo: MeshCore.DeviceInfo?
    private(set) var batteryMilliVolts: UInt16?
    private(set) var contacts: [Data: MeshCore.Contact] = [:] // keyed by full public key
    private(set) var state: TransportState = .disconnected

    private var eventContinuations: [UUID: AsyncStream<MeshEvent>.Continuation] = [:]
    private var pending: [PendingRequest] = []
    private var pumpTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var syncing = false
    private var advertRefreshInFlight = false

    private final class PendingRequest {
        enum Kind {
            case simple                 // ok/err/selfInfo/etc — single frame
            case contacts               // contactsStart ... endOfContacts
            case nextMessage            // one message or noMoreMessages
        }
        let id = UUID()
        let kind: Kind
        /// nil once resumed. A resumed-but-unanswered request stays queued as
        /// a "zombie" so it still consumes the radio's (in-order) reply —
        /// otherwise one timeout would desync every later correlation.
        var continuation: CheckedContinuation<[MeshCore.Event], Error>?
        var accumulated: [MeshCore.Event] = []

        init(kind: Kind, continuation: CheckedContinuation<[MeshCore.Event], Error>) {
            self.kind = kind
            self.continuation = continuation
        }

        func resume(returning events: [MeshCore.Event]) {
            continuation?.resume(returning: events)
            continuation = nil
        }

        func resume(throwing error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    enum SessionError: Error {
        case timeout
        case radioError
        case notStarted
    }

    init(transport: MeshTransport) {
        self.transport = transport
    }

    /// A new independent stream of mesh events for each subscriber.
    func events() -> AsyncStream<MeshEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        eventContinuations[id] = nil
    }

    private func emit(_ event: MeshEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self, transport] in
            for await frame in transport.frames() {
                guard let self else { return }
                await self.handleFrame(frame)
            }
        }
        stateTask = Task { [weak self, transport] in
            for await newState in transport.states() {
                guard let self else { return }
                await self.handleStateChange(newState)
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
        stateTask?.cancel()
        pumpTask = nil
        stateTask = nil
        failAllPending()
        transport.disconnect()
    }

    private func handleStateChange(_ newState: TransportState) {
        state = newState
        if !newState.isConnected {
            failAllPending()
        }
        emit(.stateChanged(newState))
    }

    private func failAllPending() {
        let requests = pending
        pending.removeAll()
        sendQueue.removeAll()
        requests.forEach { $0.resume(throwing: SessionError.radioError) }
    }

    // MARK: - Commands

    /// Handshake after connect. Returns the radio's self info.
    @discardableResult
    func appStart(appName: String = "Fellship") async throws -> MeshCore.SelfInfo {
        let events = try await request(MeshCore.appStartFrame(appName: appName), kind: .simple)
        guard case .selfInfo(let info)? = events.first else { throw SessionError.radioError }
        selfInfo = info
        emit(.selfInfoUpdated(info))
        return info
    }

    /// Re-reads self info (used to refresh the radio's GPS-derived position).
    @discardableResult
    func refreshSelfInfo() async throws -> MeshCore.SelfInfo {
        try await appStart()
    }

    func getContacts() async throws -> [MeshCore.Contact] {
        let events = try await request(MeshCore.getContactsFrame(), kind: .contacts)
        var result: [MeshCore.Contact] = []
        for event in events {
            if case .contact(let contact) = event {
                contacts[contact.publicKey] = contact
                result.append(contact)
            }
        }
        return result
    }

    @discardableResult
    func sendDirectText(_ text: String, to publicKey: Data,
                        attempt: UInt8 = 0) async throws -> MeshCore.SendResult {
        let frame = MeshCore.sendTxtMsgFrame(text: text, recipientPublicKeyPrefix: publicKey,
                                             attempt: attempt)
        let events = try await request(frame, kind: .simple)
        guard case .sent(let result)? = events.first else { throw SessionError.radioError }
        return result
    }

    /// Fire a CLI command at a repeater/room server (shows up on its console;
    /// replies come back as ordinary contact messages).
    @discardableResult
    func sendCommand(_ command: String, to publicKey: Data) async throws -> MeshCore.SendResult {
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Command.sendTxtMsg.rawValue)
        w.writeUInt8(MeshCore.TextType.cliData.rawValue)
        w.writeUInt8(0)
        w.writeUInt32(UInt32(clamping: Int(Date().timeIntervalSince1970)))
        w.writeBytes(publicKey.prefix(6))
        w.writeString(command)
        let events = try await request(w.data, kind: .simple)
        guard case .sent(let result)? = events.first else { throw SessionError.radioError }
        return result
    }

    func setTxPower(dBm: UInt8) async throws {
        _ = try await request(MeshCore.setTxPowerFrame(dBm: dBm), kind: .simple)
    }

    func removeContact(publicKey: Data) async throws {
        _ = try await request(MeshCore.removeContactFrame(publicKey: publicKey), kind: .simple)
        contacts[publicKey] = nil
    }

    /// Result arrives asynchronously as a `.loginResult` event.
    func login(publicKey: Data, password: String) async throws {
        _ = try await request(MeshCore.sendLoginFrame(publicKey: publicKey, password: password),
                              kind: .simple)
    }

    /// Result arrives asynchronously as a `.statusResponse` event.
    func requestStatus(publicKey: Data) async throws {
        _ = try await request(MeshCore.sendStatusReqFrame(publicKey: publicKey), kind: .simple)
    }

    /// Result arrives asynchronously as a `.telemetry` event.
    func requestTelemetry(publicKey: Data) async throws {
        _ = try await request(MeshCore.sendTelemetryReqFrame(publicKey: publicKey), kind: .simple)
    }

    func getStats(_ type: MeshCore.StatsType) async throws -> MeshCore.StatsPayload {
        let events = try await request(MeshCore.getStatsFrame(type: type), kind: .simple)
        guard case .stats(let payload)? = events.first else { throw SessionError.radioError }
        return payload
    }

    /// Launches a hop-by-hop route probe; the reply arrives asynchronously as
    /// a `.traceCompleted` event carrying the same tag.
    @discardableResult
    func tracePath(path: Data) async throws -> UInt32 {
        let tag = UInt32.random(in: 1..<UInt32.max)
        _ = try await request(MeshCore.sendTracePathFrame(tag: tag, path: path), kind: .simple)
        return tag
    }

    @discardableResult
    func sendChannelText(_ text: String, channelIndex: UInt8) async throws -> MeshCore.SendResult? {
        let frame = MeshCore.sendChannelTxtMsgFrame(text: text, channelIndex: channelIndex)
        let events = try await request(frame, kind: .simple)
        if case .sent(let result)? = events.first { return result }
        // Some firmware replies plain OK for channel sends.
        return nil
    }

    func setChannel(index: UInt8, name: String, secret: Data) async throws {
        let events = try await request(MeshCore.setChannelFrame(index: index, name: name, secret: secret), kind: .simple)
        if case .error? = events.first { throw SessionError.radioError }
    }

    func getChannel(index: UInt8) async throws -> MeshCore.ChannelInfo {
        let events = try await request(MeshCore.getChannelFrame(index: index), kind: .simple)
        guard case .channelInfo(let info)? = events.first else { throw SessionError.radioError }
        return info
    }

    func setAdvertPosition(_ coordinate: Coordinate) async throws {
        _ = try await request(MeshCore.setAdvertLatLonFrame(coordinate), kind: .simple)
    }

    func setAdvertName(_ name: String) async throws {
        _ = try await request(MeshCore.setAdvertNameFrame(name), kind: .simple)
    }

    func sendSelfAdvert(flood: Bool) async throws {
        _ = try await request(MeshCore.sendSelfAdvertFrame(flood ? .flood : .zeroHop), kind: .simple)
    }

    @discardableResult
    func readBattery() async throws -> UInt16 {
        let events = try await request(MeshCore.getBatteryVoltageFrame(), kind: .simple)
        guard case .batteryMilliVolts(let mv)? = events.first else { throw SessionError.radioError }
        batteryMilliVolts = mv
        emit(.batteryUpdated(milliVolts: mv))
        return mv
    }

    @discardableResult
    func queryDevice() async throws -> MeshCore.DeviceInfo {
        let events = try await request(MeshCore.deviceQueryFrame(), kind: .simple)
        guard case .deviceInfo(let info)? = events.first else { throw SessionError.radioError }
        deviceInfo = info
        emit(.deviceInfoUpdated(info))
        return info
    }

    // MARK: - Request plumbing

    /// MeshCore firmware answers commands strictly in order, so correlation
    /// is FIFO — which only works if frames also *leave* in the same order
    /// the pending queue was built. All sends therefore flow through one
    /// in-actor queue; per-request tasks would race and cross-match replies.
    private var sendQueue: [(frame: Data, requestID: UUID)] = []
    private var sendPumpRunning = false

    private func request(_ frame: Data, kind: PendingRequest.Kind,
                         timeout: TimeInterval = 10) async throws -> [MeshCore.Event] {
        // No connected-state guard here: the session's cached state lags the
        // transport by a task hop right after connect, and transport.send
        // already throws when there's genuinely no link.
        return try await withCheckedThrowingContinuation { continuation in
            let req = PendingRequest(kind: kind, continuation: continuation)
            pending.append(req)
            sendQueue.append((frame, req.id))
            if !sendPumpRunning {
                sendPumpRunning = true
                Task { await self.pumpSends() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.fail(requestID: req.id, with: SessionError.timeout)
            }
        }
    }

    private func pumpSends() async {
        while !sendQueue.isEmpty {
            let (frame, requestID) = sendQueue.removeFirst()
            // Skip frames whose request already failed before sending.
            guard pending.contains(where: { $0.id == requestID }) else { continue }
            do {
                try await transport.send(frame)
            } catch {
                fail(requestID: requestID, with: error)
            }
        }
        sendPumpRunning = false
    }

    private func fail(requestID: UUID, with error: Error) {
        guard let index = pending.firstIndex(where: { $0.id == requestID }) else { return }
        let req = pending[index]
        if let queueIndex = sendQueue.firstIndex(where: { $0.requestID == requestID }) {
            // Never sent: safe to drop entirely.
            sendQueue.remove(at: queueIndex)
            pending.remove(at: index)
        }
        // If it was already sent, it stays queued as a zombie to swallow the
        // radio's eventual reply.
        req.resume(throwing: error)
    }

    // MARK: - Frame handling

    private func handleFrame(_ frame: Data) async {
        let event = MeshCore.parseFrame(frame)
        switch event {
        // Pushes — never part of a request/response exchange. Push handlers
        // that themselves issue requests are spawned as separate tasks: the
        // frame pump must never await a response that only it can deliver
        // (that's a deadlock on this actor).
        case .advertReceived(let publicKey), .pathUpdated(let publicKey):
            Task { await self.handleAdvertPush(publicKey: publicKey) }
        case .sendConfirmed(let ack, let rtt):
            emit(.sendConfirmed(ackCRC: ack, roundTripMillis: rtt))
        case .messagesWaiting:
            Task { await self.drainMessageQueue() }
        case .loginResult(let prefix, let success):
            emit(.loginResult(senderPrefixHex: prefix.hexEncoded, success: success))
        case .statusResponse(let prefix, let payload):
            emit(.statusResponse(senderPrefixHex: prefix.hexEncoded, payload: payload))
        case .telemetryResponse(let prefix, let lppData):
            emit(.telemetry(senderPrefixHex: prefix.hexEncoded,
                            readings: CayenneLPP.decode(lppData)))
        case .traceData(let result):
            emit(.traceCompleted(result))
        case .rxLog(let entry):
            emit(.packetReceived(entry))
        // Unsolicited message frames can arrive outside a sync exchange on
        // some firmware; deliver them directly if no sync is pending.
        case .contactMessage(let message) where currentRequestKind != .nextMessage:
            emit(.contactMessage(message, sender: contactMatching(prefix: message.senderPublicKeyPrefix)))
        case .channelMessage(let message) where currentRequestKind != .nextMessage:
            emit(.channelMessage(message))
        default:
            deliverToPending(event)
        }
    }

    private var currentRequestKind: PendingRequest.Kind? {
        pending.first?.kind
    }

    private func deliverToPending(_ event: MeshCore.Event) {
        guard let request = pending.first else { return }

        switch request.kind {
        case .simple, .nextMessage:
            pending.removeFirst()
            request.resume(returning: [event]) // no-op for zombies
        case .contacts:
            switch event {
            case .contactsStart, .contact:
                request.accumulated.append(event) // keep accumulating
            default: // endOfContacts or anything unexpected ends the request
                pending.removeFirst()
                request.resume(returning: request.accumulated)
            }
        }
    }

    private func handleAdvertPush(publicKey: Data) async {
        // A new advert means fresh position/name data — refresh contacts and
        // surface the advertiser to listeners (public-room auto-invite hooks
        // in here). Advert bursts are common on a busy mesh; one refresh at a
        // time is plenty.
        if !advertRefreshInFlight {
            advertRefreshInFlight = true
            _ = try? await getContacts()
            advertRefreshInFlight = false
        }
        if let contact = contacts[publicKey] {
            emit(.advertHeard(contact))
        }
    }

    /// Pulls queued messages off the radio until it reports none remain.
    private func drainMessageQueue() async {
        guard !syncing else { return }
        // No connected-state check: the cached state lags the transport right
        // after connect, and the request itself fails cleanly on a dead link.
        guard pumpTask != nil else { return }
        syncing = true
        defer { syncing = false }
        var exhaustedCap = true
        defer {
            // Hit the per-drain cap with messages possibly remaining? Go
            // again rather than stranding them until the next push.
            if exhaustedCap {
                Task { await self.drainMessageQueue() }
            }
        }
        for _ in 0..<64 { // hard cap per drain to stay responsive
            guard let events = try? await request(MeshCore.syncNextMessageFrame(), kind: .nextMessage) else {
                exhaustedCap = false
                break
            }
            guard let event = events.first else {
                exhaustedCap = false
                break
            }
            switch event {
            case .contactMessage(let message):
                var sender = contactMatching(prefix: message.senderPublicKeyPrefix)
                if sender == nil {
                    // Cold contacts cache (fresh connect) — one refresh so the
                    // sender resolves; safe here because the drain runs off
                    // the frame pump.
                    _ = try? await getContacts()
                    sender = contactMatching(prefix: message.senderPublicKeyPrefix)
                }
                emit(.contactMessage(message, sender: sender))
            case .channelMessage(let message):
                emit(.channelMessage(message))
            case .noMoreMessages:
                exhaustedCap = false
                return
            default:
                exhaustedCap = false
                return
            }
        }
    }

    private func contactMatching(prefix: Data) -> MeshCore.Contact? {
        contacts.first { $0.key.prefix(6) == prefix.prefix(6) }?.value
    }
}
