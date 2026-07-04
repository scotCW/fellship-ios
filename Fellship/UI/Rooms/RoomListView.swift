import SwiftUI

struct RoomListView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var settings: AppSettings
    @State private var showCreate = false
    @State private var showJoinQR = false
    @State private var path = NavigationPath()
    @State private var didAutoOpen = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if engine.rooms.isEmpty && engine.invites.isEmpty {
                    EmptyStateView(systemImage: "person.3",
                                   title: "No rooms yet",
                                   message: "Create a room for your group, or join one from an invite. Rooms live only on members' devices — there's no server and no account.")
                } else {
                    roomList
                }
            }
            .navigationTitle("Rooms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showCreate = true
                        } label: {
                            Label("Create room", systemImage: "plus.circle")
                        }
                        Button {
                            showJoinQR = true
                        } label: {
                            Label("Join via QR code", systemImage: "qrcode.viewfinder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateRoomView()
            }
            .sheet(isPresented: $showJoinQR) {
                JoinViaQRSheet()
            }
            .onChange(of: engine.rooms.count) {
                autoOpenIfRequested()
            }
            .onAppear {
                autoOpenIfRequested()
            }
        }
    }

    /// Launch-arg driven deep link (`-launchRoomFirst YES`) used by UI
    /// automation and screenshots.
    private func autoOpenIfRequested() {
        guard !didAutoOpen,
              UserDefaults.standard.bool(forKey: "launchRoomFirst"),
              let first = engine.rooms.first else { return }
        didAutoOpen = true
        path.append(first.id)
    }

    private var roomList: some View {
        List {
            let pending = engine.invites.filter { $0.state == .received }
            if !pending.isEmpty {
                Section("Invites") {
                    ForEach(pending) { invite in
                        InviteRow(invite: invite)
                    }
                }
            }

            let active = engine.rooms.filter { engine.isActive($0) }
            let inactive = engine.rooms.filter { !engine.isActive($0) }

            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { room in
                        NavigationLink(value: room.id) { RoomRow(room: room) }
                    }
                }
            }
            if !inactive.isEmpty {
                Section(active.isEmpty ? "Rooms" : "Inactive") {
                    ForEach(inactive) { room in
                        NavigationLink(value: room.id) { RoomRow(room: room) }
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { roomID in
            if let room = engine.rooms.first(where: { $0.id == roomID }) {
                RoomDetailView(roomID: room.id)
            }
        }
    }
}

struct RoomRow: View {
    @EnvironmentObject private var engine: RoomEngine
    let room: Room

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: room.kind.systemImage)
                .font(.title2)
                .foregroundStyle(engine.isActive(room) ? Color.teal : Color.secondary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(room.name).font(.headline)
                    if room.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    StatusChip(text: room.access.displayName,
                               color: room.access == .publicRoom ? .orange : .blue)
                    if engine.isActive(room) {
                        StatusChip(text: activeLabel, color: .teal)
                    }
                    if let expiresAt = room.expiresAt {
                        StatusChip(text: "ends \(Format.ago(expiresAt))", color: .secondary)
                    }
                }
            }
            Spacer()
            if engine.myInside[room.id] == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.teal)
                    .accessibilityLabel("You are inside this zone")
            }
        }
        .padding(.vertical, 2)
    }

    private var activeLabel: String {
        let count = engine.activeMemberCount(room)
        switch room.kind {
        case .geofenced: return count == 1 ? "1 inside" : "\(count) inside"
        case .rangeBased: return count == 1 ? "1 in range" : "\(count) in range"
        }
    }
}

struct InviteRow: View {
    @EnvironmentObject private var engine: RoomEngine
    let invite: Invite
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                Image(systemName: "envelope.badge")
                    .foregroundStyle(.orange)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.roomName).font(.headline)
                    Text(invite.isAutomatic
                         ? "Automatic invite — you're in this public room's zone"
                         : "Invited by \(invite.peerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("View").font(.callout.weight(.medium))
            }
        }
        .sheet(isPresented: $showSheet) {
            InviteAcceptSheet(invite: invite)
                .presentationDetents([.medium])
        }
    }
}

struct InviteAcceptSheet: View {
    @EnvironmentObject private var engine: RoomEngine
    @Environment(\.dismiss) private var dismiss
    let invite: Invite

    /// The captured invite goes stale once the engine updates it (e.g. to
    /// `.accepted`) — always render the live copy.
    private var liveInvite: Invite {
        engine.invites.first { $0.id == invite.id } ?? invite
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: invite.roomKind.systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.teal)
                .padding(.top, 28)
            Text(invite.roomName).font(.title2.bold())
            VStack(spacing: 6) {
                Text(invite.isAutomatic
                     ? "Your device is inside this public room's zone, so a member's device sent you an invite automatically."
                     : "\(invite.peerName) invited you to join.")
                Text("Joining shares your presence — and, if this room has location sharing on, your position — with its members only. Everything stays on members' devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            if liveInvite.state == .accepted {
                ProgressView("Waiting for the room key over the mesh…")
                    .padding(.top, 4)
            }

            HStack(spacing: 12) {
                Button(role: .cancel) {
                    engine.declineInvite(liveInvite)
                    dismiss()
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await engine.acceptInvite(liveInvite) }
                } label: {
                    Text(liveInvite.state == .accepted ? "Accepted" : "Accept & join")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(liveInvite.state == .accepted)
            }
            .padding(.horizontal, 20)
            Spacer()
        }
        .onChange(of: engine.rooms.count) {
            // The room key arrived and the join completed.
            if engine.rooms.contains(where: { $0.id == invite.roomID }) {
                dismiss()
            }
        }
    }
}

struct JoinViaQRSheet: View {
    @EnvironmentObject private var engine: RoomEngine
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var feedback: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRScannerView { code in
                    join(code)
                }
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)

                Text("Scan a room QR code from another member's screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("…or paste an invite code", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Join") { join(pasted) }
                        .buttonStyle(.borderedProminent)
                        .disabled(pasted.isEmpty)
                }
                .padding(.horizontal)

                if let feedback {
                    Text(feedback)
                        .font(.callout)
                        .foregroundStyle(feedback.hasPrefix("Joined") ? .green : .red)
                }
                Spacer()
            }
            .navigationTitle("Join a room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func join(_ code: String) {
        if let name = engine.joinFromQRPayload(code.trimmingCharacters(in: .whitespacesAndNewlines)) {
            feedback = "Joined “\(name)”"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
        } else {
            feedback = "That doesn't look like a Fellship room code."
        }
    }
}
