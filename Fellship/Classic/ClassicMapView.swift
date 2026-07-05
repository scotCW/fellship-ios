import SwiftUI

/// Classic-mode map: every heard node positioned on the map with the
/// standard side controls (layers, north, recenter).
struct ClassicMapView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var settings: AppSettings

    @State private var cameraTarget: CameraTarget?
    @State private var northResetToken: UUID?
    @State private var didInitialCenter = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomLeading) {
                MapCanvas(styleURL: app.mapStyle.style,
                          markers: markers,
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
                MapSideControls(onResetNorth: { northResetToken = UUID() },
                                onRecenter: { centerOnMe() })
                    .padding(16)
                    .padding(.bottom, 24)
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !didInitialCenter, location.lastFix != nil {
                    didInitialCenter = true
                    centerOnMe()
                }
            }
            .onChange(of: location.lastFix != nil) { _, hasFix in
                if hasFix && !didInitialCenter {
                    didInitialCenter = true
                    centerOnMe()
                }
            }
        }
    }

    private var markers: [MapMarker] {
        var result: [MapMarker] = []
        if let fix = location.lastFix {
            result.append(MapMarker(id: "me", name: engine.myDisplayName,
                                    coordinate: fix.coordinate, kind: .me))
        }
        for contact in engine.nearbyContacts where contact.coordinate.isPlausible {
            result.append(MapMarker(id: contact.publicKey.hexEncoded,
                                    name: contact.name.isEmpty
                                        ? "Radio \(contact.publicKey.prefix(4).hexEncoded)"
                                        : contact.name,
                                    coordinate: contact.coordinate,
                                    kind: .contact))
        }
        return result
    }

    private func centerOnMe() {
        if let fix = location.lastFix {
            cameraTarget = CameraTarget(center: fix.coordinate, zoom: 12)
        } else if let first = engine.nearbyContacts.first(where: { $0.coordinate.isPlausible }) {
            cameraTarget = CameraTarget(center: first.coordinate, zoom: 11)
        }
    }
}
