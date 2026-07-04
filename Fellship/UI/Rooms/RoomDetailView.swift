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
                                Circle()
                                    .fill(presenceColor(member))
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
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func presenceColor(_ member: Member) -> Color {
        if member.id == engine.myIdentityHex {
            return engine.myInside[room.id] == true || room.kind == .rangeBased ? .green : .gray
        }
        guard let presence = engine.presence[room.id]?[member.id],
              presence.isFresh(interval: settings.updateIntervalSeconds) else { return .gray }
        return presence.isInside ? .green : .yellow
    }
}

struct RoomSettingsSheet: View {
    @EnvironmentObject private var engine: RoomEngine
    @Environment(\.dismiss) private var dismiss
    let roomID: String
    @State private var confirmDelete = false

    private var room: Room? {
        engine.rooms.first { $0.id == roomID }
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

                    Section("About this room") {
                        LabeledContent("Type", value: room.kind.displayName)
                        LabeledContent("Access", value: room.access.displayName)
                        LabeledContent("Lifetime", value: room.permanence == .permanent
                                       ? "Permanent"
                                       : "Ends \(room.expiresAt.map { Format.ago($0) } ?? "—")")
                        if case .circle(_, let radius) = room.boundary {
                            LabeledContent("Boundary", value: "Circle, \(Format.distance(radius, units: .metric)) radius")
                        } else if let boundary = room.boundary {
                            LabeledContent("Boundary", value: boundary.kindDescription)
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
