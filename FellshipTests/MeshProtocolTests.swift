import XCTest
@testable import Fellship

final class MeshProtocolTests: XCTestCase {
    // MARK: - Outgoing frame layouts (must match stock companion firmware)

    func testAppStartFrameLayout() {
        let frame = MeshCore.appStartFrame(appName: "Fell")
        XCTAssertEqual(frame[0], 1)              // command
        XCTAssertEqual(frame[1], 1)              // app version
        XCTAssertEqual(frame[2..<8], Data(repeating: 0, count: 6))
        XCTAssertEqual(String(decoding: frame[8...], as: UTF8.self), "Fell")
    }

    func testSendTxtMsgFrameLayout() {
        let key = Data((0..<32).map { UInt8($0) })
        let ts = Date(timeIntervalSince1970: 0x0403_0201)
        let frame = MeshCore.sendTxtMsgFrame(text: "hi", recipientPublicKeyPrefix: key,
                                             attempt: 2, timestamp: ts)
        XCTAssertEqual(frame[0], 2)              // command
        XCTAssertEqual(frame[1], 0)              // plain text type
        XCTAssertEqual(frame[2], 2)              // attempt
        XCTAssertEqual(Array(frame[3..<7]), [0x01, 0x02, 0x03, 0x04]) // LE timestamp
        XCTAssertEqual(Array(frame[7..<13]), [0, 1, 2, 3, 4, 5])      // 6-byte prefix
        XCTAssertEqual(String(decoding: frame[13...], as: UTF8.self), "hi")
    }

    func testChannelTxtMsgFrameLayout() {
        let ts = Date(timeIntervalSince1970: 1)
        let frame = MeshCore.sendChannelTxtMsgFrame(text: "yo", channelIndex: 3, timestamp: ts)
        XCTAssertEqual(frame[0], 3)
        XCTAssertEqual(frame[1], 0)
        XCTAssertEqual(frame[2], 3)
        XCTAssertEqual(Array(frame[3..<7]), [1, 0, 0, 0])
        XCTAssertEqual(String(decoding: frame[7...], as: UTF8.self), "yo")
    }

    func testSetChannelFrameFieldWidths() {
        let secret = Data((0..<16).map { UInt8($0) })
        let frame = MeshCore.setChannelFrame(index: 4, name: "fs-abc", secret: secret)
        XCTAssertEqual(frame.count, 1 + 1 + 32 + 16)
        XCTAssertEqual(frame[0], 32) // command
        XCTAssertEqual(frame[1], 4)
        // Name is zero-padded C string in a 32-byte field.
        XCTAssertEqual(String(decoding: frame[2..<8], as: UTF8.self), "fs-abc")
        XCTAssertEqual(frame[8], 0)
        XCTAssertEqual(Data(frame[34...]), secret)
    }

    func testSetChannelTruncatesLongNames() {
        let name = String(repeating: "x", count: 64)
        let frame = MeshCore.setChannelFrame(index: 0, name: name, secret: Data(count: 16))
        XCTAssertEqual(frame.count, 50)
        XCTAssertEqual(frame[33], 0, "32-byte field must stay NUL-terminated")
    }

    func testSetAdvertLatLonEncodesMicrodegrees() {
        let frame = MeshCore.setAdvertLatLonFrame(Coordinate(latitude: 1.5, longitude: -2.25))
        XCTAssertEqual(frame[0], 14)
        var reader = BinaryReader(frame.dropFirst())
        XCTAssertEqual(try reader.readInt32(), 1_500_000)
        XCTAssertEqual(try reader.readInt32(), -2_250_000)
    }

    // MARK: - Incoming frame parsing

    func testParseSelfInfoRoundTrip() {
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.selfInfo.rawValue)
        w.writeUInt8(1)   // advert type
        w.writeUInt8(22)  // tx power
        w.writeUInt8(30)  // max tx power
        w.writeBytes(Data(repeating: 0xAB, count: 32))
        w.writeInt32(37_769_400)
        w.writeInt32(-122_486_200)
        w.writeBytes(Data(repeating: 0, count: 3))
        w.writeUInt8(0)
        w.writeUInt32(910_525)
        w.writeUInt32(250_000)
        w.writeUInt8(10)
        w.writeUInt8(5)
        w.writeString("Ridge Radio")

        guard case .selfInfo(let info) = MeshCore.parseFrame(w.data) else {
            return XCTFail("expected selfInfo")
        }
        XCTAssertEqual(info.txPower, 22)
        XCTAssertEqual(info.publicKey.count, 32)
        XCTAssertEqual(info.advertCoordinate.latitude, 37.7694, accuracy: 0.0001)
        XCTAssertEqual(info.advertCoordinate.longitude, -122.4862, accuracy: 0.0001)
        XCTAssertEqual(info.radioFrequencyKHz, 910_525)
        XCTAssertEqual(info.spreadingFactor, 10)
        XCTAssertEqual(info.name, "Ridge Radio")
    }

    func testParseContactRoundTrip() {
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.contact.rawValue)
        w.writeBytes(Data(repeating: 0xCD, count: 32))
        w.writeUInt8(1)   // type
        w.writeUInt8(0)   // flags
        w.writeInt8(2)    // out path len
        w.writeBytes(Data(repeating: 0, count: 64))
        w.writeCString("Robin", fieldLength: 32)
        w.writeUInt32(1_700_000_000)
        w.writeInt32(37_000_000)
        w.writeInt32(-122_000_000)
        w.writeUInt32(1_700_000_100)

        guard case .contact(let contact) = MeshCore.parseFrame(w.data) else {
            return XCTFail("expected contact")
        }
        XCTAssertEqual(contact.name, "Robin")
        XCTAssertEqual(contact.publicKey, Data(repeating: 0xCD, count: 32))
        XCTAssertEqual(contact.coordinate.latitude, 37.0, accuracy: 0.0001)
        XCTAssertEqual(contact.lastAdvert.timeIntervalSince1970, 1_700_000_000, accuracy: 0.5)
    }

    func testParseContactAndChannelMessages() {
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.contactMsgRecv.rawValue)
        w.writeBytes(Data([1, 2, 3, 4, 5, 6]))
        w.writeUInt8(0)
        w.writeUInt8(0)
        w.writeUInt32(1_700_000_000)
        w.writeString("hello mesh")
        guard case .contactMessage(let dm) = MeshCore.parseFrame(w.data) else {
            return XCTFail("expected contactMessage")
        }
        XCTAssertEqual(dm.senderPublicKeyPrefix, Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(dm.text, "hello mesh")

        var c = BinaryWriter()
        c.writeUInt8(MeshCore.Response.channelMsgRecv.rawValue)
        c.writeInt8(2)
        c.writeUInt8(1)
        c.writeUInt8(0)
        c.writeUInt32(1_700_000_000)
        c.writeString("channel text")
        guard case .channelMessage(let cm) = MeshCore.parseFrame(c.data) else {
            return XCTFail("expected channelMessage")
        }
        XCTAssertEqual(cm.channelIndex, 2)
        XCTAssertEqual(cm.text, "channel text")
    }

    func testParseSentAndPushes() {
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.sent.rawValue)
        w.writeInt8(0)
        w.writeUInt32(0xDEADBEEF)
        w.writeUInt32(4000)
        guard case .sent(let result) = MeshCore.parseFrame(w.data) else {
            return XCTFail("expected sent")
        }
        XCTAssertEqual(result.expectedAckCRC, 0xDEADBEEF)
        XCTAssertEqual(result.estimatedTimeoutMillis, 4000)

        var p = BinaryWriter()
        p.writeUInt8(MeshCore.Push.sendConfirmed.rawValue)
        p.writeUInt32(0xDEADBEEF)
        p.writeUInt32(1234)
        guard case .sendConfirmed(let ack, let rtt) = MeshCore.parseFrame(p.data) else {
            return XCTFail("expected sendConfirmed")
        }
        XCTAssertEqual(ack, 0xDEADBEEF)
        XCTAssertEqual(rtt, 1234)

        var advert = BinaryWriter()
        advert.writeUInt8(MeshCore.Push.advert.rawValue)
        advert.writeBytes(Data(repeating: 7, count: 32))
        guard case .advertReceived(let key) = MeshCore.parseFrame(advert.data) else {
            return XCTFail("expected advert")
        }
        XCTAssertEqual(key, Data(repeating: 7, count: 32))

        guard case .messagesWaiting = MeshCore.parseFrame(Data([MeshCore.Push.msgWaiting.rawValue])) else {
            return XCTFail("expected msgWaiting")
        }
    }

    func testMalformedFramesDoNotCrash() {
        // Truncated at every length up to a full selfInfo — parser must
        // return .unknown, never trap.
        var w = BinaryWriter()
        w.writeUInt8(MeshCore.Response.selfInfo.rawValue)
        w.writeBytes(Data(repeating: 1, count: 10)) // way too short
        if case .selfInfo = MeshCore.parseFrame(w.data) {
            XCTFail("should not parse truncated selfInfo")
        }
        _ = MeshCore.parseFrame(Data())
        _ = MeshCore.parseFrame(Data([0xFF]))
        _ = MeshCore.parseFrame(Data([MeshCore.Response.contact.rawValue, 1, 2]))
    }

    func testBatteryAndChannelInfo() {
        var b = BinaryWriter()
        b.writeUInt8(MeshCore.Response.batteryVoltage.rawValue)
        b.writeUInt16(4012)
        guard case .batteryMilliVolts(let mv) = MeshCore.parseFrame(b.data) else {
            return XCTFail("expected battery")
        }
        XCTAssertEqual(mv, 4012)

        var c = BinaryWriter()
        c.writeUInt8(MeshCore.Response.channelInfo.rawValue)
        c.writeUInt8(3)
        c.writeCString("fs-room", fieldLength: 32)
        c.writeBytes(Data(repeating: 9, count: 16))
        guard case .channelInfo(let info) = MeshCore.parseFrame(c.data) else {
            return XCTFail("expected channelInfo")
        }
        XCTAssertEqual(info.index, 3)
        XCTAssertEqual(info.name, "fs-room")
        XCTAssertEqual(info.secret, Data(repeating: 9, count: 16))
    }

    // MARK: - BinaryReader safety

    func testBinaryReaderOutOfBoundsThrows() {
        var r = BinaryReader(Data([1, 2]))
        XCTAssertEqual(try r.readUInt8(), 1)
        XCTAssertThrowsError(try r.readUInt32())
    }

    func testBinaryReaderHandlesDataSlices() {
        // Data slices keep their parent's indices; the reader must re-base.
        let parent = Data([9, 9, 9, 1, 2, 3, 4])
        let slice = parent.dropFirst(3)
        var r = BinaryReader(slice)
        XCTAssertEqual(try r.readUInt32(), 0x04030201)
    }
}
