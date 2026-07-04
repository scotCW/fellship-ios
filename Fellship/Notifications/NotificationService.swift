import Foundation
import UserNotifications

/// Local notifications only — there is no push server anywhere in Fellship
/// (spec §8). Notifications fire when the app processes a mesh event, so all
/// copy says "shortly after", matching how iOS background delivery really
/// behaves.
@MainActor
final class NotificationService: ObservableObject {
    @Published private(set) var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func refreshAuthorizationState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.authorized = settings.authorizationStatus == .authorized
            }
        }
    }

    enum Kind {
        case zoneEntry(memberName: String, roomName: String)
        case zoneExit(memberName: String, roomName: String)
        case presenceJoined(memberName: String, roomName: String)
        case presenceLeft(memberName: String, roomName: String)
        case message(senderName: String, roomName: String?, preview: String)
        case inviteReceived(roomName: String, inviterName: String, automatic: Bool)
        case roomExpired(roomName: String)

        var title: String {
            switch self {
            case .zoneEntry(let member, let room): return "\(member) arrived in \(room)"
            case .zoneExit(let member, let room): return "\(member) left \(room)"
            case .presenceJoined(let member, let room): return "\(member) is in range of \(room)"
            case .presenceLeft(let member, let room): return "\(member) dropped out of range of \(room)"
            case .message(let sender, let room, _):
                if let room { return "\(sender) in \(room)" }
                return sender
            case .inviteReceived(let room, _, _): return "Invite to \(room)"
            case .roomExpired(let room): return "\(room) has ended"
            }
        }

        var body: String {
            switch self {
            case .zoneEntry, .zoneExit, .presenceJoined, .presenceLeft:
                // Honest about background lag (spec §8): events surface
                // shortly after they happen, not instantly.
                return "Detected a few moments ago over the mesh."
            case .message(_, _, let preview):
                return preview
            case .inviteReceived(_, let inviter, let automatic):
                return automatic
                    ? "You're inside this public room's zone. \(inviter)'s device sent you an invite — join if you'd like."
                    : "\(inviter) invited you. Accept to join."
            case .roomExpired:
                return "This temporary room reached its end time and was removed from your device."
            }
        }
    }

    func post(_ kind: Kind, threadID: String? = nil) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = kind.title
        content.body = kind.body
        content.sound = .default
        if let threadID {
            content.threadIdentifier = threadID
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil) // deliver immediately
        UNUserNotificationCenter.current().add(request)
    }
}
