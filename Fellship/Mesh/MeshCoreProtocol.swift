import Foundation

/// The stock MeshCore companion-radio protocol, as implemented by unmodified
/// firmware and documented by the open-source reference clients
/// (github.com/liamcottle/meshcore.js). Fellship speaks this protocol as-is —
/// no custom firmware, no protocol extensions (spec §1).
enum MeshCore {
    /// Nordic UART Service, used by MeshCore companion BLE.
    static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Phone → radio writes.
    static let rxCharacteristicUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Radio → phone notifications.
    static let txCharacteristicUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    enum Command: UInt8 {
        case appStart = 1
        case sendTxtMsg = 2
        case sendChannelTxtMsg = 3
        case getContacts = 4
        case getDeviceTime = 5
        case setDeviceTime = 6
        case sendSelfAdvert = 7
        case setAdvertName = 8
        case addUpdateContact = 9
        case syncNextMessage = 10
        case setTxPower = 12
        case resetPath = 13
        case setAdvertLatLon = 14
        case removeContact = 15
        case shareContact = 16
        case exportContact = 17
        case importContact = 18
        case getBatteryVoltage = 20
        case deviceQuery = 22
        case sendLogin = 26
        case sendStatusReq = 27
        case getChannel = 31
        case setChannel = 32
        case sendTracePath = 36
        case sendTelemetryReq = 39
        case getStats = 56
    }

    enum Response: UInt8 {
        case ok = 0
        case err = 1
        case contactsStart = 2
        case contact = 3
        case endOfContacts = 4
        case selfInfo = 5
        case sent = 6
        case contactMsgRecv = 7
        case channelMsgRecv = 8
        case currTime = 9
        case noMoreMessages = 10
        case batteryVoltage = 12
        case deviceInfo = 13
        case channelInfo = 18
        case stats = 24
    }

    enum Push: UInt8 {
        case advert = 0x80
        case pathUpdated = 0x81
        case sendConfirmed = 0x82
        case msgWaiting = 0x83
        case loginSuccess = 0x85
        case loginFail = 0x86
        case statusResponse = 0x87
        case logRxData = 0x88
        case traceData = 0x89
        case newAdvert = 0x8A
        case telemetryResponse = 0x8B
    }

    enum StatsType: UInt8 {
        case core = 0
        case radio = 1
        case packets = 2
    }

    enum TextType: UInt8 {
        case plain = 0
        case cliData = 1
        case signedPlain = 2
    }

    enum SelfAdvertType: UInt8 {
        case zeroHop = 0
        case flood = 1
    }

    // MARK: - Outgoing frames

    static func appStartFrame(appName: String) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.appStart.rawValue)
        w.writeUInt8(1) // app version
        w.writeBytes(Data(repeating: 0, count: 6)) // reserved
        w.writeString(appName)
        return w.data
    }

    static func sendTxtMsgFrame(text: String, recipientPublicKeyPrefix: Data,
                                attempt: UInt8 = 0, timestamp: Date = Date()) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.sendTxtMsg.rawValue)
        w.writeUInt8(TextType.plain.rawValue)
        w.writeUInt8(attempt)
        w.writeUInt32(UInt32(clamping: Int(timestamp.timeIntervalSince1970)))
        w.writeBytes(recipientPublicKeyPrefix.prefix(6))
        w.writeString(text)
        return w.data
    }

    static func sendChannelTxtMsgFrame(text: String, channelIndex: UInt8,
                                       timestamp: Date = Date()) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.sendChannelTxtMsg.rawValue)
        w.writeUInt8(TextType.plain.rawValue)
        w.writeUInt8(channelIndex)
        w.writeUInt32(UInt32(clamping: Int(timestamp.timeIntervalSince1970)))
        w.writeString(text)
        return w.data
    }

    static func getContactsFrame(since: Date? = nil) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.getContacts.rawValue)
        if let since {
            w.writeUInt32(UInt32(clamping: Int(since.timeIntervalSince1970)))
        }
        return w.data
    }

    static func syncNextMessageFrame() -> Data {
        Data([Command.syncNextMessage.rawValue])
    }

    static func sendSelfAdvertFrame(_ type: SelfAdvertType) -> Data {
        Data([Command.sendSelfAdvert.rawValue, type.rawValue])
    }

    static func setAdvertNameFrame(_ name: String) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.setAdvertName.rawValue)
        w.writeString(name)
        return w.data
    }

    static func setAdvertLatLonFrame(_ coordinate: Coordinate) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.setAdvertLatLon.rawValue)
        w.writeInt32(coordinate.microdegreesLat)
        w.writeInt32(coordinate.microdegreesLon)
        return w.data
    }

    static func getBatteryVoltageFrame() -> Data {
        Data([Command.getBatteryVoltage.rawValue])
    }

    static func deviceQueryFrame(appTargetVersion: UInt8 = 1) -> Data {
        Data([Command.deviceQuery.rawValue, appTargetVersion])
    }

    static func setTxPowerFrame(dBm: UInt8) -> Data {
        Data([Command.setTxPower.rawValue, dBm])
    }

    static func removeContactFrame(publicKey: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.removeContact.rawValue)
        w.writeBytes(pad(publicKey, to: 32))
        return w.data
    }

    /// Writes (adds or updates) a contact in the radio's own persistent
    /// contact list. This is how a contact becomes durable — the radio, not
    /// the app, is the store of record.
    static func addUpdateContactFrame(publicKey: Data, type: UInt8, flags: UInt8,
                                      outPathLength: Int8, outPath: Data,
                                      name: String, lastAdvert: Date,
                                      coordinate: Coordinate) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.addUpdateContact.rawValue)
        w.writeBytes(pad(publicKey, to: 32))
        w.writeUInt8(type)
        w.writeUInt8(flags)
        w.writeInt8(outPathLength)
        w.writeBytes(pad(outPath, to: 64))
        w.writeCString(name, fieldLength: 32)
        w.writeUInt32(UInt32(clamping: Int(lastAdvert.timeIntervalSince1970)))
        w.writeInt32(coordinate.microdegreesLat)
        w.writeInt32(coordinate.microdegreesLon)
        return w.data
    }

    static func resetPathFrame(publicKey: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.resetPath.rawValue)
        w.writeBytes(pad(publicKey, to: 32))
        return w.data
    }

    /// Asks the radio to re-broadcast a contact over the mesh so nearby nodes
    /// can pick it up.
    static func shareContactFrame(publicKey: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.shareContact.rawValue)
        w.writeBytes(pad(publicKey, to: 32))
        return w.data
    }

    /// Exports a contact's advert blob (or, with no key, the radio's own
    /// identity) for out-of-band sharing.
    static func exportContactFrame(publicKey: Data?) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.exportContact.rawValue)
        if let publicKey { w.writeBytes(pad(publicKey, to: 32)) }
        return w.data
    }

    static func importContactFrame(advertPacket: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.importContact.rawValue)
        w.writeBytes(advertPacket)
        return w.data
    }

    /// Right-pads (or truncates) to an exact fixed width.
    private static func pad(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data.prefix(length) }
        return data + Data(count: length - data.count)
    }

    /// Authenticate against a repeater/room server (max 15-char password).
    static func sendLoginFrame(publicKey: Data, password: String) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.sendLogin.rawValue)
        w.writeBytes(publicKey.prefix(32))
        w.writeString(String(password.prefix(15)))
        return w.data
    }

    static func sendStatusReqFrame(publicKey: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.sendStatusReq.rawValue)
        w.writeBytes(publicKey.prefix(32))
        return w.data
    }

    /// Trace a route hop by hop. `path` is the known out-path hash bytes for
    /// the destination (empty = probe direct neighbors / flood).
    static func sendTracePathFrame(tag: UInt32, path: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.sendTracePath.rawValue)
        w.writeUInt32(tag)
        w.writeUInt32(0) // auth
        w.writeUInt8(0)  // flags
        w.writeBytes(path)
        return w.data
    }

    static func getStatsFrame(type: StatsType) -> Data {
        Data([Command.getStats.rawValue, type.rawValue])
    }

    static func sendTelemetryReqFrame(publicKey: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.sendTelemetryReq.rawValue)
        w.writeBytes(Data([0, 0, 0])) // reserved
        w.writeBytes(publicKey.prefix(32))
        return w.data
    }

    static func getChannelFrame(index: UInt8) -> Data {
        Data([Command.getChannel.rawValue, index])
    }

    static func setChannelFrame(index: UInt8, name: String, secret: Data) -> Data {
        var w = BinaryWriter()
        w.writeUInt8(Command.setChannel.rawValue)
        w.writeUInt8(index)
        w.writeCString(name, fieldLength: 32)
        w.writeBytes(secret.prefix(16))
        return w.data
    }

    // MARK: - Incoming frames

    struct SelfInfo: Equatable, Sendable {
        var advertType: UInt8
        var txPower: UInt8
        var maxTxPower: UInt8
        var publicKey: Data
        var advertCoordinate: Coordinate
        var radioFrequencyKHz: UInt32
        var radioBandwidthHz: UInt32
        var spreadingFactor: UInt8
        var codingRate: UInt8
        var name: String
    }

    struct Contact: Equatable, Sendable {
        var publicKey: Data
        var type: UInt8
        var flags: UInt8
        var outPathLength: Int8
        /// The routing path (node hash bytes) currently used to reach this
        /// contact — what trace-path probes hop along.
        var outPath: Data
        var name: String
        var lastAdvert: Date
        var coordinate: Coordinate
        var lastModified: Date
    }

    struct ContactMessage: Equatable, Sendable {
        var senderPublicKeyPrefix: Data
        var pathLength: UInt8
        var textType: UInt8
        var senderTimestamp: Date
        var text: String
    }

    struct ChannelMessage: Equatable, Sendable {
        var channelIndex: Int8
        var pathLength: UInt8
        var textType: UInt8
        var senderTimestamp: Date
        var text: String
    }

    struct ChannelInfo: Equatable, Sendable {
        var index: UInt8
        var name: String
        var secret: Data
    }

    struct SendResult: Equatable, Sendable {
        var result: Int8
        var expectedAckCRC: UInt32
        var estimatedTimeoutMillis: UInt32
    }

    struct DeviceInfo: Equatable, Sendable {
        var firmwareVersion: Int8
        var firmwareBuildDate: String
        var manufacturerModel: String
    }

    enum StatsPayload: Equatable, Sendable {
        case core(batteryMilliVolts: UInt16, uptimeSeconds: UInt32, queueLength: UInt8)
        case radio(noiseFloor: Int16, lastRSSI: Int8, lastSNR: Double,
                   txAirSeconds: UInt32, rxAirSeconds: UInt32)
        case packets(received: UInt32, sent: UInt32, sentFlood: UInt32,
                     sentDirect: UInt32, receivedFlood: UInt32,
                     receivedDirect: UInt32, receiveErrors: UInt32?)
    }

    /// One hop-by-hop route probe result.
    struct TraceResult: Equatable, Sendable {
        var tag: UInt32
        var pathHashes: [UInt8]
        /// SNR in dB at each hop, same order as `pathHashes`.
        var pathSNRs: [Double]
        var finalSNR: Double
    }

    /// A raw received-packet log entry (packet monitor).
    struct RxLogEntry: Equatable, Sendable {
        var snr: Double
        var rssi: Int8
        var payload: Data
    }

    enum Event: Sendable {
        case ok
        case error
        case selfInfo(SelfInfo)
        case contactsStart
        case contact(Contact)
        case endOfContacts
        case sent(SendResult)
        case contactMessage(ContactMessage)
        case channelMessage(ChannelMessage)
        case currentTime(Date)
        case noMoreMessages
        case batteryMilliVolts(UInt16)
        case deviceInfo(DeviceInfo)
        case channelInfo(ChannelInfo)
        case advertReceived(publicKey: Data)
        case pathUpdated(publicKey: Data)
        case sendConfirmed(ackCRC: UInt32, roundTripMillis: UInt32)
        case messagesWaiting
        case loginResult(senderPrefix: Data, success: Bool)
        case statusResponse(senderPrefix: Data, payload: Data)
        case telemetryResponse(senderPrefix: Data, lppData: Data)
        case stats(StatsPayload)
        case traceData(TraceResult)
        case rxLog(RxLogEntry)
        case unknown(code: UInt8, payload: Data)
    }

    /// Parses one incoming frame (response or push) from the radio.
    static func parseFrame(_ frame: Data) -> Event {
        guard let code = frame.first else { return .unknown(code: 0, payload: Data()) }
        var r = BinaryReader(frame.dropFirst())
        do {
            if let response = Response(rawValue: code) {
                switch response {
                case .ok: return .ok
                case .err: return .error
                case .contactsStart: return .contactsStart
                case .contact: return .contact(try parseContact(&r))
                case .endOfContacts: return .endOfContacts
                case .selfInfo: return .selfInfo(try parseSelfInfo(&r))
                case .sent:
                    return .sent(SendResult(result: try r.readInt8(),
                                            expectedAckCRC: try r.readUInt32(),
                                            estimatedTimeoutMillis: try r.readUInt32()))
                case .contactMsgRecv:
                    return .contactMessage(ContactMessage(
                        senderPublicKeyPrefix: try r.readBytes(6),
                        pathLength: try r.readUInt8(),
                        textType: try r.readUInt8(),
                        senderTimestamp: Date(timeIntervalSince1970: TimeInterval(try r.readUInt32())),
                        text: r.readStringToEnd()))
                case .channelMsgRecv:
                    return .channelMessage(ChannelMessage(
                        channelIndex: try r.readInt8(),
                        pathLength: try r.readUInt8(),
                        textType: try r.readUInt8(),
                        senderTimestamp: Date(timeIntervalSince1970: TimeInterval(try r.readUInt32())),
                        text: r.readStringToEnd()))
                case .currTime:
                    return .currentTime(Date(timeIntervalSince1970: TimeInterval(try r.readUInt32())))
                case .noMoreMessages: return .noMoreMessages
                case .batteryVoltage: return .batteryMilliVolts(try r.readUInt16())
                case .deviceInfo:
                    let version = try r.readInt8()
                    try r.skip(6)
                    let buildDate = try r.readCString(fieldLength: 12)
                    return .deviceInfo(DeviceInfo(firmwareVersion: version,
                                                  firmwareBuildDate: buildDate,
                                                  manufacturerModel: r.readStringToEnd()))
                case .channelInfo:
                    return .channelInfo(ChannelInfo(index: try r.readUInt8(),
                                                    name: try r.readCString(fieldLength: 32),
                                                    secret: try r.readBytes(min(16, r.remainingCount))))
                case .stats:
                    return .stats(try parseStats(&r))
                }
            }
            if let push = Push(rawValue: code) {
                switch push {
                case .advert, .newAdvert:
                    return .advertReceived(publicKey: try r.readBytes(32))
                case .pathUpdated:
                    return .pathUpdated(publicKey: try r.readBytes(32))
                case .sendConfirmed:
                    return .sendConfirmed(ackCRC: try r.readUInt32(),
                                          roundTripMillis: try r.readUInt32())
                case .msgWaiting:
                    return .messagesWaiting
                case .loginSuccess, .loginFail:
                    try r.skip(1) // reserved
                    return .loginResult(senderPrefix: try r.readBytes(6),
                                        success: push == .loginSuccess)
                case .statusResponse:
                    try r.skip(1)
                    let prefix = try r.readBytes(6)
                    return .statusResponse(senderPrefix: prefix,
                                           payload: try r.readBytes(r.remainingCount))
                case .logRxData:
                    let snr = Double(try r.readInt8()) / 4
                    let rssi = try r.readInt8()
                    return .rxLog(RxLogEntry(snr: snr, rssi: rssi,
                                             payload: try r.readBytes(r.remainingCount)))
                case .traceData:
                    try r.skip(1) // reserved
                    let pathLen = Int(try r.readUInt8())
                    try r.skip(1) // flags
                    let tag = try r.readUInt32()
                    _ = try r.readUInt32() // auth code
                    let hashes = try r.readBytes(pathLen)
                    let snrs = try r.readBytes(pathLen)
                    let finalSNR = Double(try r.readInt8()) / 4
                    return .traceData(TraceResult(
                        tag: tag,
                        pathHashes: Array(hashes),
                        pathSNRs: snrs.map { Double(Int8(bitPattern: $0)) / 4 },
                        finalSNR: finalSNR))
                case .telemetryResponse:
                    try r.skip(1)
                    let prefix = try r.readBytes(6)
                    return .telemetryResponse(senderPrefix: prefix,
                                              lppData: try r.readBytes(r.remainingCount))
                }
            }
        } catch {
            return .unknown(code: code, payload: Data(frame.dropFirst()))
        }
        return .unknown(code: code, payload: Data(frame.dropFirst()))
    }

    private static func parseSelfInfo(_ r: inout BinaryReader) throws -> SelfInfo {
        let advertType = try r.readUInt8()
        let txPower = try r.readUInt8()
        let maxTxPower = try r.readUInt8()
        let publicKey = try r.readBytes(32)
        let lat = try r.readInt32()
        let lon = try r.readInt32()
        try r.skip(3) // reserved
        try r.skip(1) // manualAddContacts
        let freq = try r.readUInt32()
        let bw = try r.readUInt32()
        let sf = try r.readUInt8()
        let cr = try r.readUInt8()
        return SelfInfo(advertType: advertType,
                        txPower: txPower,
                        maxTxPower: maxTxPower,
                        publicKey: publicKey,
                        advertCoordinate: Coordinate(microdegreesLat: lat, microdegreesLon: lon),
                        radioFrequencyKHz: freq,
                        radioBandwidthHz: bw,
                        spreadingFactor: sf,
                        codingRate: cr,
                        name: r.readStringToEnd())
    }

    private static func parseStats(_ r: inout BinaryReader) throws -> StatsPayload {
        let type = try r.readUInt8()
        switch StatsType(rawValue: type) {
        case .core:
            return .core(batteryMilliVolts: try r.readUInt16(),
                         uptimeSeconds: try r.readUInt32(),
                         queueLength: try r.readUInt8())
        case .radio:
            let noise = Int16(bitPattern: try r.readUInt16())
            let rssi = try r.readInt8()
            let snr = Double(try r.readInt8()) / 4
            return .radio(noiseFloor: noise, lastRSSI: rssi, lastSNR: snr,
                          txAirSeconds: try r.readUInt32(),
                          rxAirSeconds: try r.readUInt32())
        case .packets:
            let recv = try r.readUInt32()
            let sent = try r.readUInt32()
            let sentFlood = try r.readUInt32()
            let sentDirect = try r.readUInt32()
            let recvFlood = try r.readUInt32()
            let recvDirect = try r.readUInt32()
            let errors = r.remainingCount >= 4 ? try r.readUInt32() : nil
            return .packets(received: recv, sent: sent, sentFlood: sentFlood,
                            sentDirect: sentDirect, receivedFlood: recvFlood,
                            receivedDirect: recvDirect, receiveErrors: errors)
        case nil:
            throw BinaryReader.ReaderError.outOfBounds
        }
    }

    private static func parseContact(_ r: inout BinaryReader) throws -> Contact {
        let publicKey = try r.readBytes(32)
        let type = try r.readUInt8()
        let flags = try r.readUInt8()
        let outPathLength = try r.readInt8()
        let rawPath = try r.readBytes(64)
        let outPath = outPathLength > 0 ? rawPath.prefix(Int(min(outPathLength, 64))) : Data()
        let name = try r.readCString(fieldLength: 32)
        let lastAdvert = Date(timeIntervalSince1970: TimeInterval(try r.readUInt32()))
        let lat = try r.readInt32()
        let lon = try r.readInt32()
        let lastMod = Date(timeIntervalSince1970: TimeInterval(try r.readUInt32()))
        return Contact(publicKey: publicKey,
                       type: type,
                       flags: flags,
                       outPathLength: outPathLength,
                       outPath: Data(outPath),
                       name: name,
                       lastAdvert: lastAdvert,
                       coordinate: Coordinate(microdegreesLat: lat, microdegreesLon: lon),
                       lastModified: lastMod)
    }
}
