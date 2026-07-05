import Foundation
import CryptoKit
import CommonCrypto

/// Passphrase-encrypted backup of everything that matters: rooms, their keys,
/// members, and message history. The file is useless without the passphrase —
/// PBKDF2-SHA256 (210k rounds) derives the key, ChaCha20-Poly1305 seals the
/// payload, so tampering is detected and brute force is expensive.
///
/// This is an owner-approved amendment to the original "no recovery" spec
/// rule: backups are explicit, user-initiated, user-held files — there is
/// still no cloud and no automatic copy anywhere.
enum BackupService {
    static let magic = Data("FSBK1".utf8)
    static let pbkdf2Rounds: UInt32 = 210_000

    struct Payload: Codable {
        var version: Int = 1
        var createdAt = Date()
        var displayName: String
        /// Curve25519 identity private key — restoring on a fresh install
        /// keeps your member identity in old rooms.
        var identityKey: Data?
        var rooms: [Room]
        var membersByRoom: [String: [Member]]
        var messages: [RoomMessage]
        /// roomID → symmetric room key bytes.
        var roomKeys: [String: Data]
    }

    enum BackupError: LocalizedError {
        case malformedFile
        case wrongPassphrase
        case emptyPassphrase

        var errorDescription: String? {
            switch self {
            case .malformedFile: return "That file isn't a Fellship backup."
            case .wrongPassphrase: return "Wrong passphrase (or the file is damaged)."
            case .emptyPassphrase: return "Choose a passphrase first."
            }
        }
    }

    // MARK: - Key derivation

    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var derived = Data(count: 32)
        let passphraseData = Data(passphrase.utf8)
        derived.withUnsafeMutableBytes { derivedBytes in
            passphraseData.withUnsafeBytes { passBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBytes.bindMemory(to: Int8.self).baseAddress,
                        passphraseData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Rounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        32)
                }
            }
        }
        return SymmetricKey(data: derived)
    }

    // MARK: - Encode / decode

    static func encrypt(_ payload: Payload, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw BackupError.emptyPassphrase }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = try encoder.encode(payload)
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try ChaChaPoly.seal(json, using: key, authenticating: magic)
        return magic + salt + sealed.combined
    }

    static func decrypt(_ file: Data, passphrase: String) throws -> Payload {
        guard !passphrase.isEmpty else { throw BackupError.emptyPassphrase }
        guard file.count > magic.count + 16 + 28,
              file.prefix(magic.count) == magic else {
            throw BackupError.malformedFile
        }
        let salt = file.subdata(in: magic.count..<(magic.count + 16))
        let boxData = file.subdata(in: (magic.count + 16)..<file.count)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        guard let box = try? ChaChaPoly.SealedBox(combined: boxData),
              let json = try? ChaChaPoly.open(box, using: key, authenticating: magic) else {
            throw BackupError.wrongPassphrase
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(Payload.self, from: json) else {
            throw BackupError.malformedFile
        }
        return payload
    }

    // MARK: - Gather / restore

    @MainActor
    static func gather(engine: RoomEngine, settings: AppSettings) -> Payload {
        var membersByRoom: [String: [Member]] = [:]
        var roomKeys: [String: Data] = [:]
        var messages: [RoomMessage] = []
        for room in engine.rooms {
            membersByRoom[room.id] = engine.members(of: room)
            if let key = CryptoService.roomKey(for: room.id) {
                roomKeys[room.id] = key.dataRepresentation
            }
            messages.append(contentsOf: engine.messages(threadID: room.id))
        }
        for thread in engine.directThreads() {
            messages.append(contentsOf: engine.messages(threadID: thread.peerHex))
        }
        return Payload(displayName: settings.displayName,
                       identityKey: CryptoService.identityPrivateKeyData(),
                       rooms: engine.rooms,
                       membersByRoom: membersByRoom,
                       messages: messages,
                       roomKeys: roomKeys)
    }

    /// Merges a backup into the current install. Returns a human summary.
    @MainActor
    static func restore(_ payload: Payload, engine: RoomEngine, settings: AppSettings) -> String {
        // Identity: adopt only on a fresh install (no rooms yet) — swapping
        // identity under existing rooms would orphan your membership in them.
        var identityRestored = false
        if engine.rooms.isEmpty, let identity = payload.identityKey {
            identityRestored = CryptoService.adoptIdentity(identity)
        }
        if settings.displayName.isEmpty && !payload.displayName.isEmpty {
            settings.displayName = payload.displayName
        }

        var roomsAdded = 0
        for room in payload.rooms where !engine.rooms.contains(where: { $0.id == room.id }) {
            guard let keyData = payload.roomKeys[room.id] else { continue }
            let manifest = FellshipEnvelope.RoomManifest(
                room: room,
                members: payload.membersByRoom[room.id] ?? [],
                roomKeyData: keyData)
            engine.joinRoom(manifest: manifest)
            roomsAdded += 1
        }

        var messagesAdded = 0
        for message in payload.messages {
            if (try? engine.store.saveMessage(message)) != nil {
                messagesAdded += 1
            }
        }
        engine.chatRevision += 1

        var summary = "Restored \(roomsAdded) room\(roomsAdded == 1 ? "" : "s") and \(messagesAdded) messages."
        if identityRestored {
            summary += " Your identity was restored too."
        }
        return summary
    }

    static func suggestedFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "Fellship-Backup-\(formatter.string(from: Date())).fellshipbackup"
    }
}
