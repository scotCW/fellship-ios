import SwiftUI

/// The main map: every joined room's boundary, member positions where rooms
/// share them, and my own position from the active GPS source.
struct MapScreen: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var location: LocationService

    @State private var cameraTarget: CameraTarget?
    @State private var didInitialCenter = false
    @State private var northResetToken: UUID?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomLeading) {
                MapCanvas(styleURL: app.mapStyle.style,
                          markers: markers,
                          boundaries: boundaries,
                          cameraTarget: cameraTarget,
                          northResetToken: northResetToken)
                    .ignoresSafeArea(edges: .top)

                VStack(alignment: .leading, spacing: 8) {
                    if settings.demoMode { DemoBanner() }
                    GPSSourceBadge()
                    Text(app.mapStyle.attribution)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                MapSideControls(
                    onResetNorth: { northResetToken = UUID() },
                    onRecenter: { centerOnMe() },
                    extra: firstBoundedRoom.map { room in
                        (icon: "square.dashed", label: "Center on \(room.name)",
                         action: { center(on: room) })
                    })
                    .padding(16)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    connectionIndicator
                }
            }
            .onAppear {
                if !didInitialCenter, location.lastFix != nil {
                    didInitialCenter = true
                    centerOnMe()
                }
            }
            .onChange(of: location.lastFix != nil) { _, hasFix in
                // First GPS fix after launch: bring the camera home once.
                if hasFix && !didInitialCenter {
                    didInitialCenter = true
                    centerOnMe()
                }
            }
        }
    }

    private var connectionIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(app.transportState.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(app.transportState.isConnected ? "Radio" : "No radio")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var firstBoundedRoom: Room? {
        engine.rooms.first { $0.kind == .geofenced && $0.boundary != nil }
    }

    private var boundaries: [MapBoundaryOverlay] {
        engine.rooms.compactMap { room in
            guard let boundary = room.boundary else { return nil }
            return MapBoundaryOverlay(id: room.id, boundary: boundary,
                                      isActive: engine.isActive(room))
        }
    }

    private var markers: [MapMarker] {
        var result: [MapMarker] = []
        if let fix = location.lastFix {
            result.append(MapMarker(id: "me", name: engine.myDisplayName,
                                    coordinate: fix.coordinate, kind: .me))
        }
        // One marker per member, from the freshest room presence that
        // includes coordinates. Stale positions don't belong on the map —
        // a marker implies "this is where they are".
        var best: [String: (MemberPresence, String)] = [:]
        for room in engine.rooms {
            for presence in engine.presenceList(for: room)
            where presence.coordinate != nil
                && presence.isFresh(interval: settings.updateIntervalSeconds) {
                if let existing = best[presence.memberID]?.0,
                   existing.lastHeard >= presence.lastHeard { continue }
                best[presence.memberID] = (presence, room.id)
            }
        }
        for (memberID, (presence, roomID)) in best {
            guard let coordinate = presence.coordinate else { continue }
            let name = engine.rooms.first(where: { $0.id == roomID })
                .flatMap { room in engine.members(of: room).first { $0.id == memberID }?.displayName }
                ?? "Member"
            result.append(MapMarker(id: memberID, name: name, coordinate: coordinate, kind: .member))
        }
        return result
    }

    private func centerOnMe() {
        if let fix = location.lastFix {
            cameraTarget = CameraTarget(center: fix.coordinate, zoom: 13)
        } else if let room = firstBoundedRoom, let boundary = room.boundary {
            cameraTarget = CameraTarget(center: GeoMath.enclosingCircle(of: boundary).center, zoom: 12)
        }
    }

    private func center(on room: Room) {
        guard let boundary = room.boundary else { return }
        let circle = GeoMath.enclosingCircle(of: boundary)
        cameraTarget = CameraTarget(center: circle.center, zoom: 13)
    }
}
