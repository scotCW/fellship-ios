import SwiftUI

/// Contacts heard on the mesh, with favorites, node type, and per-node tools
/// (telemetry, repeater login, CLI, removal).
struct ClassicContactsView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            Group {
                if engine.nearbyContacts.isEmpty {
                    EmptyStateView(systemImage: "person.2",
                                   title: "No contacts yet",
                                   message: "Radios are added automatically when their adverts are heard. Ask nearby nodes to send an advert, or send yours from the Radio tab.")
                } else {
                    contactList
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await engine.refreshContacts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!app.transportState.isConnected)
                    .accessibilityLabel("Refresh contacts")
                }
            }
        }
    }

    private var contactList: some View {
        let sorted = engine.nearbyContacts.sorted { a, b in
            let aFav = classic.favorites.contains(a.publicKey.prefix(6).hexEncoded)
            let bFav = classic.favorites.contains(b.publicKey.prefix(6).hexEncoded)
            if aFav != bFav { return aFav }
            return a.lastAdvert > b.lastAdvert
        }
        return List(sorted, id: \.publicKey) { contact in
            NavigationLink {
                ClassicContactDetailView(contact: contact)
            } label: {
                ContactRow(contact: contact)
            }
        }
    }
}

private struct ContactRow: View {
    @EnvironmentObject private var classic: ClassicStore
    let contact: MeshCore.Contact

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: contact.type == 2 ? "antenna.radiowaves.left.and.right.circle" : "person.circle")
                .font(.title2)
                .foregroundStyle(contact.type == 2 ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name.isEmpty ? "Radio \(contact.publicKey.prefix(4).hexEncoded)" : contact.name)
                    .font(.headline)
                Text("\(contact.type == 2 ? "Repeater" : "Companion") · heard \(Format.ago(contact.lastAdvert))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if classic.favorites.contains(contact.publicKey.prefix(6).hexEncoded) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
        }
    }
}

/// Node detail: info, telemetry, repeater login + CLI, chat, remove.
struct ClassicContactDetailView: View {
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let contact: MeshCore.Contact

    @State private var password = ""
    @State private var cliCommand = ""
    @State private var confirmRemove = false
    @State private var requestedTelemetry = false

    private var prefixHex: String { contact.publicKey.prefix(6).hexEncoded }
    private var isRepeater: Bool { contact.type == 2 }

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: isRepeater ? "Repeater" : "Companion radio")
                LabeledContent("Last advert", value: Format.ago(contact.lastAdvert))
                if contact.coordinate.isPlausible {
                    LabeledContent("Position", value: Format.coordinate(contact.coordinate))
                }
                LabeledContent("Public key") {
                    Text(contact.publicKey.hexEncoded.prefix(16) + "…")
                        .font(.caption.monospaced())
                }
                Button {
                    classic.toggleFavorite(prefixHex)
                } label: {
                    Label(classic.favorites.contains(prefixHex) ? "Unfavorite" : "Favorite",
                          systemImage: classic.favorites.contains(prefixHex) ? "star.slash" : "star")
                }
            }

            Section("Telemetry") {
                if let readings = classic.telemetry[prefixHex], !readings.isEmpty {
                    ForEach(readings) { reading in
                        LabeledContent(reading.label, value: reading.value)
                    }
                } else if requestedTelemetry {
                    HStack {
                        ProgressView()
                        Text("Waiting for reply over the mesh…")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    requestedTelemetry = true
                    Task { await classic.requestTelemetry(contact: contact) }
                } label: {
                    Label("Request telemetry", systemImage: "waveform.path.ecg")
                }
            }

            if !isRepeater {
                Section {
                    NavigationLink {
                        DirectChatScreen(peerHex: contact.publicKey.hexEncoded,
                                         peerName: contact.name)
                    } label: {
                        Label("Message \(contact.name)", systemImage: "message")
                    }
                }
            }

            if isRepeater {
                repeaterSection
            }

            Section {
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label("Remove from radio", systemImage: "trash")
                }
            } footer: {
                Text("Removes this contact from the radio's own contact list. It reappears if its advert is heard again.")
            }
        }
        .navigationTitle(contact.name.isEmpty ? "Node" : contact.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(contact.name)?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await classic.removeContact(contact)
                    await engine.refreshContacts()
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var repeaterSection: some View {
        Section {
            switch classic.loginStates[prefixHex] {
            case .loggedIn:
                Label("Logged in", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            case .loggingIn:
                HStack {
                    ProgressView()
                    Text("Logging in…").foregroundStyle(.secondary)
                }
            case .failed:
                Label("Login failed — check the password", systemImage: "xmark.seal")
                    .foregroundStyle(.red)
            case nil:
                EmptyView()
            }
            SecureField("Repeater password", text: $password)
            Button("Log in") {
                Task { await classic.login(contact: contact, password: password) }
            }
            .disabled(password.isEmpty)
        } header: {
            Text("Repeater access")
        }

        Section {
            TextField("Command (e.g. ver, clock, advert)", text: $cliCommand)
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                let command = cliCommand.trimmingCharacters(in: .whitespaces)
                guard !command.isEmpty else { return }
                cliCommand = ""
                Task { await classic.sendCommand(command, to: contact) }
            } label: {
                Label("Send command", systemImage: "terminal")
            }
            .disabled(cliCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            NavigationLink {
                DirectChatScreen(peerHex: contact.publicKey.hexEncoded,
                                 peerName: contact.name)
            } label: {
                Label("Console replies", systemImage: "text.alignleft")
            }
        } header: {
            Text("Remote console")
        } footer: {
            Text("Commands run on the repeater's CLI (after login). Replies arrive as messages in the console thread.")
        }
    }
}
