import SwiftUI

struct RoomDetailView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let roomID: String

    @State private var showSettings = false
    @State private var showInvitePicker = false
    @State private var showQRShare = false

    private var room: Room? {
        engine.rooms.first { $0.id == roomID }
    }

    var body: some View {
        Group {
            if let room {
                content(room)
            } else {
                // Room was deleted (possibly expired) while open.
                EmptyStateView(systemImage: "clock.badge.xmark",
                               title: "Room ended",
                               message: "This room no longer exists on this device.")
            }
        }
    }

    private func content(_ room: Room) -> some View {
        VStack(spacing: 0) {
            header(room)
            Divider()
            ChatView(threadID: room.id, room: room)
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showInvitePicker = true
                    } label: {
                        Label("Invite someone nearby", systemImage: "person.badge.plus")
                    }
                    Button {
                        showQRShare = true
                    } label: {
                        Label("Share join QR code", systemImage: "qrcode")
                    }
                    Divider()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Room settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Room actions")
            }
        }
        .sheet(isPresented: $showSettings) {
            RoomSettingsSheet(roomID: room.id)
        }
        .sheet(isPresented: $showInvitePicker) {
            InvitePickerSheet(room: room)
        }
        .sheet(isPresented: $showQRShare) {
            QRShareSheet(room: room)
        }
    }

    private func header(_ room: Room) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                StatusChip(text: engine.isActive(room) ? "Active" : "Inactive",
                           color: engine.isActive(room) ? .teal : .secondary)
                StatusChip(text: room.kind.displayName, color: .blue)
                StatusChip(text: room.access.displayName,
                           color: room.access == .publicRoom ? .orange : .blue)
                if room.kind == .geofenced {
                    switch engine.myInside[room.id] {
                    case .some(true): StatusChip(text: "You're inside", color: .teal)
                    case .some(false): StatusChip(text: "You're outside", color: .secondary)
                    case .none: StatusChip(text: "Waiting for GPS", color: .orange)
                    }
                }
                Spacer()
            }
            MemberStrip(room: room)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Horizontal member list with live presence.
struct MemberStrip: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let room: Room

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(engine.members(of: room)) { member in
                    NavigationLink {
                        LocateMemberView(room: room, member: member)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottomTrailing) {
                                Circle()
                                    .fill(member.id == engine.myIdentityHex ? Color.blue : Color.teal)
                                    .frame(width: 42, height: 42)
                                    .overlay {
                                        Text(String(member.displayName.prefix(1)).uppercased())
                                            .font(.headline)
                                            .foregroundStyle(.white)
                                    }
                                // Presence is also stated in the accessibility
                                // label below (for VoiceOver), and with
                                // "Differentiate Without Color Alone" on, the
                                // dot itself switches to a shape cue — a
                                // colorblind user doesn't need to read hue.
                                presenceIndicator(member)
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.background, lineWidth: 2))
                            }
                            Text(member.id == engine.myIdentityHex ? "You" : member.displayName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(member.id == engine.myIdentityHex)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(member.id == engine.myIdentityHex ? "You" : member.displayName), \(presenceDescription(presenceState(member)))")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private enum PresenceState { case inside, outside, unknown }

    /// Single source of truth for a member's presence — color, text, and
    /// icon are all derived from this so they can't drift apart.
    private func presenceState(_ member: Member) -> PresenceState {
        if member.id == engine.myIdentityHex {
            return (engine.myInside[room.id] == true || room.kind == .rangeBased) ? .inside : .outside
        }
        guard let presence = engine.presence[room.id]?[member.id],
              presence.isFresh(interval: settings.updateIntervalSeconds) else { return .unknown }
        return presence.isInside ? .inside : .outside
    }

    private func presenceColor(_ state: PresenceState) -> Color {
        switch state {
        case .inside: return .green
        case .outside: return .yellow
        case .unknown: return .gray
        }
    }

    /// Text equivalent, so who's currently present isn't conveyed by color
    /// alone for VoiceOver users.
    private func presenceDescription(_ state: PresenceState) -> String {
        switch state {
        case .inside: return "inside the room"
        case .outside: return "outside the room"
        case .unknown: return "presence unknown"
        }
    }

    /// Shape equivalent, for sighted users with "Differentiate Without Color
    /// Alone" turned on — three distinct silhouettes rather than three hues.
    private func presenceSymbol(_ state: PresenceState) -> String {
        switch state {
        case .inside: return "checkmark.circle.fill"
        case .outside: return "circle"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    @ViewBuilder
    private func presenceIndicator(_ member: Member) -> some View {
        let state = presenceState(member)
        if differentiateWithoutColor {
            Image(systemName: presenceSymbol(state))
                .resizable()
                .scaledToFit()
                .foregroundStyle(presenceColor(state))
        } else {
            Circle().fill(presenceColor(state))
        }
    }
}

/// Read-only map of a room's boundary, shown to every member in room
/// settings. The area is shared state — knowing where the room *is* shouldn't
/// be a privilege of whoever happened to create it.
struct RoomAreaPreview: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var location: LocationService
    let room: Room
    let boundary: Boundary

    var body: some View {
        let enclosing = GeoMath.enclosingCircle(of: boundary)
        MapCanvas(styleURL: app.mapStyle.style,
                  markers: myMarker,
                  boundaries: [MapBoundaryOverlay(id: room.id,
                                                  boundary: boundary,
                                                  isActive: engine.isActive(room))],
                  cameraTarget: CameraTarget(center: enclosing.center,
                                             zoom: zoom(forRadius: enclosing.radiusMeters),
                                             animated: false))
            .allowsHitTesting(false)
    }

    private var myMarker: [MapMarker] {
        guard let mine = location.lastFix?.coordinate else { return [] }
        return [MapMarker(id: "me", name: "You", coordinate: mine, kind: .me)]
    }

    /// Pick a zoom that fits the whole boundary in the preview.
    private func zoom(forRadius meters: Double) -> Double {
        // Each zoom level halves the ground covered; z13 ≈ 1 km across a
        // preview this size, so scale from there and clamp to sane bounds.
        let target = max(meters, 50) * 2.4
        let zoom = 13.0 - log2(target / 1_000)
        return min(17, max(3, zoom))
    }
}

struct RoomSettingsSheet: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let roomID: String
    @State private var confirmDelete = false

    private var room: Room? {
        engine.rooms.first { $0.id == roomID }
    }

    /// Plain-language description of the room's area, in the user's units.
    /// Shown to every member — the boundary is shared state, not something
    /// only the creator should be able to see.
    private func areaDescription(_ boundary: Boundary) -> String {
        switch boundary {
        case .circle(_, let radius):
            return "Circle, \(Format.distance(radius, units: settings.units)) radius."
        case .box:
            let (_, radius) = GeoMath.enclosingCircle(of: boundary)
            return "Box, about \(Format.distance(radius * 2, units: settings.units)) across."
        case .polygon(let vertices):
            let (_, radius) = GeoMath.enclosingCircle(of: boundary)
            return "Outline with \(vertices.count) corners, about \(Format.distance(radius * 2, units: settings.units)) across."
        }
    }

    var body: some View {
        NavigationStack {
            if let room {
                Form {
                    Section {
                        Toggle("Share precise locations", isOn: Binding(
                            get: { room.sharesPreciseLocation },
                            set: { newValue in
                                var updated = room
                                updated.sharesPreciseLocation = newValue
                                engine.updateRoom(updated)
                            }))
                        Toggle("Mute notifications", isOn: Binding(
                            get: { room.isMuted },
                            set: { newValue in
                                var updated = room
                                updated.isMuted = newValue
                                engine.updateRoom(updated)
                            }))
                    } footer: {
                        Text("Location sharing is enforced when your device broadcasts: with it off, your coordinates are never transmitted to this room — not merely hidden.")
                    }

                    if let boundary = room.boundary {
                        Section {
                            RoomAreaPreview(room: room, boundary: boundary)
                                .frame(height: 190)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .listRowInsets(EdgeInsets())
                        } header: {
                            Text("Room area")
                        } footer: {
                            Text(areaDescription(boundary)
                                 + (engine.myInside[room.id] == true
                                    ? " You're inside it now."
                                    : engine.myInside[room.id] == false
                                      ? " You're currently outside it."
                                      : " Your position isn't known yet."))
                        }
                    }

                    Section("About this room") {
                        LabeledContent("Type", value: room.kind.displayName)
                        LabeledContent("Access", value: room.access.displayName)
                        LabeledContent("Lifetime", value: room.permanence == .permanent
                                       ? "Permanent"
                                       : "Ends \(room.expiresAt.map { Format.ago($0) } ?? "—")")
                        if let boundary = room.boundary {
                            LabeledContent("Boundary", value: areaDescription(boundary))
                        }
                        LabeledContent("Members", value: "\(engine.members(of: room).count)")
                    }

                    Section {
                        Button("Delete room from this device", role: .destructive) {
                            confirmDelete = true
                        }
                    } footer: {
                        Text("Deletion is permanent. The room's key, members and full history are removed from this device and cannot be recovered — there is no backup anywhere. Other members keep their own copies.")
                    }
                }
                .navigationTitle("Room settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .confirmationDialog("Delete “\(room.name)” forever?",
                                    isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete forever", role: .destructive) {
                        engine.deleteRoom(room)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Pick a nearby radio contact to invite.
struct InvitePickerSheet: View {
    @EnvironmentObject private var engine: RoomEngine
    @Environment(\.dismiss) private var dismiss
    let room: Room
    @State private var sentTo: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if engine.nearbyContacts.isEmpty {
                    EmptyStateView(systemImage: "dot.radiowaves.left.and.right",
                                   title: "Nobody heard yet",
                                   message: "Radios appear here when their adverts are heard over the mesh. Ask your friend to send an advert from their radio, or share the room's QR code instead.")
                } else {
                    List(engine.nearbyContacts, id: \.publicKey) { contact in
                        let hex = contact.publicKey.hexEncoded
                        let isMember = engine.members(of: room).contains { $0.radioPublicKey == hex }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name.isEmpty ? "Radio \(hex.prefix(8))" : contact.name)
                                    .font(.headline)
                                Text("Heard \(Format.ago(contact.lastAdvert))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isMember {
                                Text("Member").font(.caption).foregroundStyle(.secondary)
                            } else if sentTo.contains(hex) {
                                Label("Invited", systemImage: "checkmark")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                            } else {
                                Button("Invite") {
                                    sentTo.insert(hex)
                                    Task { await engine.sendInvite(room: room, to: contact) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Invite to \(room.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await engine.refreshContacts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh nearby radios")
                }
            }
        }
    }
}

/// Shows the room's QR credential for face-to-face joining.
struct QRShareSheet: View {
    @EnvironmentObject private var engine: RoomEngine
    @Environment(\.dismiss) private var dismiss
    let room: Room

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let payload = engine.makeQRPayload(room: room),
                   let image = QRSupport.generate(from: payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    Text("Anyone who scans this joins “\(room.name)” instantly — including the room key. Show it only to people you want in the room.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else {
                    EmptyStateView(systemImage: "qrcode",
                                   title: "QR unavailable",
                                   message: "This room couldn't be encoded as a QR code. Invite members over the mesh instead.")
                }
                Spacer()
            }
            .padding(.top, 30)
            .navigationTitle("Share room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
