import SwiftUI

/// Room creation wizard: basics → boundary (for geofenced rooms) → review.
struct CreateRoomView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var settings: AppSettings
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
    /// Circle radius as a 0…1 log-scale slider position (precise at 100 m
    /// and usable at 10,000 mi on the same control).
    @State private var circleSliderPosition = 0.35
    @State private var boxCornerA: Coordinate?
    @State private var boxCornerB: Coordinate?
    /// Tap-placed polygon corners, joined by straight lines.
    @State private var vertices: [Coordinate] = []
    /// The outline only becomes a usable zone once explicitly closed.
    @State private var isShapeClosed = false
    @State private var cameraTarget: CameraTarget?
    @State private var step = 0

    private var circleRadius: Double {
        LogScale.value(at: circleSliderPosition,
                       min: AppSettings.minCircleRadiusMeters,
                       max: settings.maxCircleRadiusMeters)
    }

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
                    if step == 1 {
                        Button("Back") { step = 0 }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
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
                      draftPolygon: isShapeClosed ? [] : vertices,
                      draftBoundary: draftBoundary,
                      tapToPlaceEnabled: tool == .outline && !isShapeClosed,
                      cameraTarget: cameraTarget,
                      onMapTap: { point in
                          vertices.append(point)
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
            guard isShapeClosed, vertices.count >= 3 else { return nil }
            return .polygon(vertices: vertices)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if location.lastFix == nil {
                Label("No GPS fix yet — pan the map to the area you want",
                      systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Shape", selection: $tool) {
                ForEach(BoundaryTool.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)

            switch tool {
            case .circle:
                VStack(spacing: 4) {
                    Slider(value: $circleSliderPosition, in: 0...1)
                    Text("Radius: \(Format.distance(circleRadius, units: settings.units)) — pan the map to position the center")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Slider max is \(Format.distance(settings.maxCircleRadiusMeters, units: settings.units)) — raise it in Settings → Zones")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                VStack(spacing: 8) {
                    Text(isShapeClosed
                         ? "Shape closed — \(vertices.count) corners. Reopen to keep editing."
                         : (vertices.isEmpty
                            ? "Tap the map to drop corners — straight lines connect them."
                            : "\(vertices.count) corner\(vertices.count == 1 ? "" : "s") placed. Close the shape when the zone is enclosed."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Button {
                            isShapeClosed.toggle()
                        } label: {
                            Text(isShapeClosed ? "Reopen" : "Close shape")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isShapeClosed && vertices.count < 3)
                        Button("Undo corner") {
                            isShapeClosed = false
                            _ = vertices.popLast()
                        }
                        .buttonStyle(.bordered)
                        .disabled(vertices.isEmpty)
                        Button("Clear") {
                            vertices.removeAll()
                            isShapeClosed = false
                        }
                        .buttonStyle(.bordered)
                        .disabled(vertices.isEmpty)
                    }
                    .font(.callout)
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
        var boundary: Boundary?
        if kind == .geofenced {
            guard let draft = draftBoundary else { return }
            boundary = draft
            // A finger trace can produce hundreds of vertices; decimate so the
            // boundary stays cheap to check and small enough to share (the QR
            // invite embeds the full geometry).
            if case .polygon(let vertices) = draft, vertices.count > 64 {
                let step = Double(vertices.count) / 64.0
                let sampled = (0..<64).map { vertices[Int(Double($0) * step)] }
                boundary = .polygon(vertices: sampled)
            }
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
