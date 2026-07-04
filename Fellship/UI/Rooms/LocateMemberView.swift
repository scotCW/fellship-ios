import SwiftUI

/// Distance + compass bearing to a member — works fully offline. Uses the
/// member's last shared position (if this room shares locations) and the
/// phone's compass.
struct LocateMemberView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var settings: AppSettings
    let room: Room
    let member: Member

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            if let target = targetCoordinate, let mine = location.lastFix?.coordinate {
                let distance = GeoMath.distanceMeters(mine, target)
                let bearing = GeoMath.bearingDegrees(from: mine, to: target)
                let heading = location.headingDegrees ?? 0
                let needle = bearing - heading

                ZStack {
                    Circle()
                        .stroke(.quaternary, lineWidth: 3)
                        .frame(width: 220, height: 220)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.teal)
                        .rotationEffect(.degrees(needle))
                        .animation(.easeInOut(duration: 0.3), value: needle)
                }
                VStack(spacing: 6) {
                    Text(Format.distance(distance, units: settings.units))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text("bearing \(Int(bearing.rounded()))°")
                        .foregroundStyle(.secondary)
                    if let presence = engine.presence[room.id]?[member.id] {
                        Text("Position from \(Format.ago(presence.lastHeard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if location.headingDegrees == nil {
                        Text("Compass unavailable — arrow shows map bearing from north")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            } else if !room.sharesPreciseLocation {
                EmptyStateView(systemImage: "location.slash",
                               title: "No location shared",
                               message: "“\(room.name)” doesn't share precise locations, so there's nothing to point at. Presence still shows who's in the room.")
            } else {
                EmptyStateView(systemImage: "location.magnifyingglass",
                               title: "No position yet",
                               message: "Waiting for \(member.displayName)'s next presence broadcast and a GPS fix on this device.")
            }
            Spacer()
        }
        .padding()
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { location.startHeadingUpdates() }
        .onDisappear { location.stopHeadingUpdates() }
    }

    private var targetCoordinate: Coordinate? {
        engine.presence[room.id]?[member.id]?.coordinate
    }
}
