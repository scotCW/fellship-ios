import SwiftUI

/// Room creation wizard: basics → boundary (for geofenced rooms) → review.
struct CreateRoomView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var location: LocationService
    @Environment(\.dismiss) private var dismiss

    // Basics
    @State private var name = ""
    @State private var kind: RoomKind = .geofenced
    @State private var access: RoomAccess = .inviteOnly
    @State private var permanence: Permanence = .temporary
    @State private var durationHours: Double = 24
    @State private var sharesLocation = true

    // Boundary drawing
    enum BoundaryTool: String, CaseIterable, Identifiable {
        case circle = "Circle"
        case box = "Box"
        case outline = "Outline"
        var id: String { rawValue }
    }
    @State private var tool: BoundaryTool = .circle
    @State private var mapCenter: Coordinate?
    @State private var circleRadius: Double = 300
    @State private var boxCornerA: Coordinate?
    @State private var boxCornerB: Coordinate?
    @State private var tracedPoints: [Coordinate] = []
    @State private var isTracing = false
    @State private var cameraTarget: CameraTarget?
    @State private var step = 0

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 {
                    basicsForm
                } else {
                    boundaryEditor
                }
            }
            .navigationTitle(step == 0 ? "New room" : "Draw the zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if step == 0 && kind == .geofenced {
                        Button("Next") { step = 1 }
                            .disabled(!basicsValid)
                    } else {
                        Button("Create") { create() }
                            .disabled(!formValid)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .onAppear {
            if let fix = location.lastFix {
                cameraTarget = CameraTarget(center: fix.coordinate, zoom: 14, animated: false)
            }
        }
    }

    // MARK: Step 1 — basics

    private var basicsForm: some View {
        Form {
            Section("Name") {
                TextField("e.g. Cabin Weekend", text: $name)
            }
            Section {
                Picker("Type", selection: $kind) {
                    ForEach([RoomKind.geofenced, .rangeBased], id: \.self) { k in
                        Label(k.displayName, systemImage: k.systemImage).tag(k)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Room type")
            } footer: {
                Text(kind == .geofenced
                     ? "Members are “in the room” when they're inside a zone you draw on the map."
                     : "Members are “in the room” whenever their radios can reach each other over the mesh — great for convoys and road trips. Range isn't a fixed line: terrain, obstacles and antennas make it fluctuate.")
            }
            Section {
                Picker("Joining", selection: $access) {
                    ForEach([RoomAccess.inviteOnly, .publicRoom], id: \.self) { a in
                        Label(a.displayName, systemImage: a.systemImage).tag(a)
                    }
                }
                Picker("Lifetime", selection: $permanence) {
                    Text("Temporary").tag(Permanence.temporary)
                    Text("Permanent").tag(Permanence.permanent)
                }
                if permanence == .temporary {
                    VStack(alignment: .leading) {
                        Slider(value: $durationHours, in: 1...168, step: 1)
                        Text("Ends after \(Int(durationHours)) hours")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Access & lifetime")
            } footer: {
                if access == .publicRoom {
                    Text("Anyone nearby with “alert me about public rooms” turned on gets an automatic invite when they're in this room's zone or range — they still have to accept.")
                }
            }
            Section {
                Toggle("Share precise locations", isOn: $sharesLocation)
            } footer: {
                Text("When off, members' presence is shared but their coordinates are never transmitted for this room. This is a per-room setting — you can change it later.")
            }
        }
    }

    private var basicsValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Step 2 — boundary

    private var boundaryEditor: some View {
        ZStack(alignment: .bottom) {
            MapCanvas(styleURL: app.mapStyle.style,
                      markers: [],
                      boundaries: [],
                      draftPolygon: tracedPoints,
                      draftBoundary: draftBoundary,
                      isTracing: isTracing,
                      cameraTarget: cameraTarget,
                      onTracePoint: { point in
                          if tracedPoints.isEmpty
                              || GeoMath.distanceMeters(tracedPoints.last!, point) > 5 {
                              tracedPoints.append(point)
                          }
                      },
                      onCameraIdle: { center, _ in
                          mapCenter = center
                      })
                .ignoresSafeArea(edges: .bottom)

            if tool != .outline {
                // Crosshair marking the map center used to place shapes.
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            controls
        }
    }

    private var draftBoundary: Boundary? {
        switch tool {
        case .circle:
            guard let center = mapCenter else { return nil }
            return .circle(center: center, radiusMeters: circleRadius)
        case .box:
            guard let a = boxCornerA else { return nil }
            let b = boxCornerB ?? mapCenter ?? a
            return .box(cornerA: a, cornerB: b)
        case .outline:
            guard tracedPoints.count >= 3 else { return nil }
            return .polygon(vertices: tracedPoints)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Shape", selection: $tool) {
                ForEach(BoundaryTool.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)

            switch tool {
            case .circle:
                VStack(spacing: 4) {
                    Slider(value: $circleRadius, in: 50...5000, step: 25)
                    Text("Radius: \(Format.distance(circleRadius, units: .metric)) — pan the map to position the center")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .box:
                HStack(spacing: 10) {
                    Button(boxCornerA == nil ? "Set corner 1" : "Corner 1 ✓") {
                        boxCornerA = mapCenter
                    }
                    .buttonStyle(.bordered)
                    Button(boxCornerB == nil ? "Set corner 2" : "Corner 2 ✓") {
                        boxCornerB = mapCenter
                    }
                    .buttonStyle(.bordered)
                    .disabled(boxCornerA == nil)
                    if boxCornerA != nil {
                        Button("Reset") {
                            boxCornerA = nil
                            boxCornerB = nil
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .font(.callout)
            case .outline:
                HStack(spacing: 10) {
                    Button(isTracing ? "Stop drawing" : (tracedPoints.isEmpty ? "Start drawing" : "Keep drawing")) {
                        isTracing.toggle()
                    }
                    .buttonStyle(.borderedProminent)
                    if !tracedPoints.isEmpty {
                        Button("Clear") {
                            tracedPoints.removeAll()
                            isTracing = false
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("\(tracedPoints.count) points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
    }

    private var formValid: Bool {
        guard basicsValid else { return false }
        if kind == .geofenced && step == 1 {
            return draftBoundary != nil
        }
        return true
    }

    private func create() {
        let boundary: Boundary?
        if kind == .geofenced {
            guard let draft = draftBoundary else { return }
            boundary = draft
        } else {
            boundary = nil
        }
        engine.createRoom(name: name.trimmingCharacters(in: .whitespaces),
                          kind: kind,
                          boundary: boundary,
                          access: access,
                          permanence: permanence,
                          duration: durationHours * 3600,
                          sharesPreciseLocation: sharesLocation)
        dismiss()
    }
}
