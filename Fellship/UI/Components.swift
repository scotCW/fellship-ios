import SwiftUI

/// Small status chip (Active / Inactive / In range…).
struct StatusChip: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Consistent empty-state presentation.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
    }
}

/// Room type icon.
extension RoomKind {
    var systemImage: String {
        switch self {
        case .geofenced: return "mappin.and.ellipse.circle"
        case .rangeBased: return "dot.radiowaves.left.and.right"
        }
    }

    var displayName: String {
        switch self {
        case .geofenced: return "Geofenced"
        case .rangeBased: return "Range-based"
        }
    }
}

extension RoomAccess {
    var displayName: String {
        switch self {
        case .inviteOnly: return "Invite-only"
        case .publicRoom: return "Public"
        }
    }

    var systemImage: String {
        switch self {
        case .inviteOnly: return "lock"
        case .publicRoom: return "person.wave.2"
        }
    }
}

extension DeliveryState {
    var symbol: String {
        switch self {
        case .sent: return "checkmark"
        case .heard: return "checkmark.circle.fill"
        case .timedOut: return "exclamationmark.circle"
        case .received: return ""
        }
    }

    var label: String {
        switch self {
        case .sent: return "Sent to mesh"
        case .heard: return "Heard by mesh"
        case .timedOut: return "Not confirmed"
        case .received: return ""
        }
    }
}

/// Subtle banner shown while demo mode is on.
struct DemoBanner: View {
    var body: some View {
        Label("Demo mode — simulated radio and members", systemImage: "sparkles")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(.orange)
    }
}

/// GPS source indicator (spec §4: make the fallback explicit). When there is
/// no source at all, says so instead of disappearing — a silent blank map
/// helps nobody.
struct GPSSourceBadge: View {
    @EnvironmentObject private var location: LocationService

    var body: some View {
        if let fix = location.lastFix {
            Label(fix.source == .radio ? "Radio GPS" : "Phone GPS",
                  systemImage: fix.source == .radio ? "antenna.radiowaves.left.and.right" : "iphone")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        } else {
            Label("No position — connect a radio or allow location",
                  systemImage: "location.slash")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }
}
