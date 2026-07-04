import Foundation
import CryptoKit

/// All cryptography in Fellship goes through CryptoKit — no hand-rolled
/// primitives. Design:
///
/// * Each device has a long-lived Curve25519 **identity keypair** (the public
///   key doubles as the member ID).
/// * Each room has a 256-bit **symmetric room key** (ChaChaPoly), generated at
///   room creation and stored only in the Keychain of each member's device.
/// * Room traffic (presence, chat, events) is sealed with the room key, with
///   the room ID bound in as additional authenticated data.
/// * At invite acceptance the room key travels over the mesh inside an
///   **anonymous sealed box**: an ephemeral Curve25519 key agrees with the
///   recipient's identity key, HKDF-SHA256 derives a wrapping key, and
///   ChaChaPoly seals the payload. Losing a device means losing its rooms —
///   there is deliberately no escrow anywhere.
enum CryptoService {
    private static let keychain = KeychainStore()
    private static let identityKeyName = "fellship.identity.curve25519"
    private static let hkdfInfoSealedBox = Data("fellship.sealedbox.v1".utf8)
    private static let hkdfInfoChannel = Data("fellship.channel.v1".utf8)

    enum CryptoError: Error {
        case malformedPayload
        case keyMissing
    }

    // MARK: - Identity

    /// Loads the device identity, creating it on first use.
    static func identity() -> Curve25519.KeyAgreement.PrivateKey {
        if let raw = keychain.load(identityKeyName),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try? keychain.save(key.rawRepresentation, for: identityKeyName)
        return key
    }

    static func identityPublicKeyHex() -> String {
        identity().publicKey.rawRepresentation.hexEncoded
    }

    // MARK: - Room keys

    static func generateRoomKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    static func storeRoomKey(_ key: SymmetricKey, roomID: String) throws {
        try keychain.save(key.dataRepresentation, for: "room.\(roomID)")
    }

    static func roomKey(for roomID: String) -> SymmetricKey? {
        keychain.load("room.\(roomID)").map(SymmetricKey.init(data:))
    }

    static func deleteRoomKey(roomID: String) {
        keychain.delete("room.\(roomID)")
    }

    /// Derives the 16-byte pre-shared key used to configure the room's
    /// MeshCore channel slot. Members-only can derive it, so even the packet
    /// envelope is invisible to non-members at the transport layer — the
    /// app-layer encryption above it is what the spec's Section 6 requires,
    /// and this PSK is defense in depth, not the primary protection.
    static func channelPSK(roomKey: SymmetricKey) -> Data {
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: roomKey,
                                             info: hkdfInfoChannel,
                                             outputByteCount: 16)
        return derived.dataRepresentation
    }

    // MARK: - Room traffic

    static func seal(_ plaintext: Data, roomKey: SymmetricKey, roomID: String) throws -> Data {
        let sealed = try ChaChaPoly.seal(plaintext, using: roomKey,
                                         authenticating: Data(roomID.utf8))
        return sealed.combined
    }

    static func open(_ combined: Data, roomKey: SymmetricKey, roomID: String) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: roomKey,
                                   authenticating: Data(roomID.utf8))
    }

    // MARK: - Sealed box (invite key delivery)

    /// Seals `plaintext` so only the holder of `recipientPublicKey` can read it.
    /// Output layout: ephemeralPublicKey (32) || ChaChaPoly combined box.
    static func sealBox(_ plaintext: Data, recipientPublicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipientPublicKey)
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeral.publicKey.rawRepresentation + recipientPublicKey.rawRepresentation,
            sharedInfo: hkdfInfoSealedBox,
            outputByteCount: 32)
        let sealed = try ChaChaPoly.seal(plaintext, using: wrapKey)
        return ephemeral.publicKey.rawRepresentation + sealed.combined
    }

    static func openBox(_ payload: Data, identity: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard payload.count > 32 else { throw CryptoError.malformedPayload }
        let ephemeralRaw = payload.prefix(32)
        let boxData = payload.dropFirst(32)
        let ephemeralPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralRaw)
        let shared = try identity.sharedSecretFromKeyAgreement(with: ephemeralPub)
        let wrapKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: ephemeralRaw + identity.publicKey.rawRepresentation,
            sharedInfo: hkdfInfoSealedBox,
            outputByteCount: 32)
        let box = try ChaChaPoly.SealedBox(combined: boxData)
        return try ChaChaPoly.open(box, using: wrapKey)
    }
}

extension SymmetricKey {
    var dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}

extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexEncoded string: String) {
        let chars = Array(string.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
        }
        self.init(bytes)
    }
}
