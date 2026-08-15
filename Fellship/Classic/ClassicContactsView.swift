import SwiftUI

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
    @State private var showTelemetry = false
    @State private var showCardQR = false
    @State private var actionNote: String?

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
                Button {
                    showTelemetry = true
                    Task { await classic.requestTelemetry(contact: contact) }
                } label: {
                    Label("Request telemetry", systemImage: "waveform.path.ecg")
                }
                if let readings = classic.telemetry[prefixHex], !readings.isEmpty {
                    Button {
                        showTelemetry = true
                    } label: {
                        Label("Last readings (\(readings.count))", systemImage: "list.bullet.rectangle")
                    }
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
                Button {
                    showCardQR = true
                } label: {
                    Label("Share as QR code", systemImage: "qrcode")
                }
                Button {
                    Task {
                        await classic.shareOverMesh(contact)
                        actionNote = "Shared over the mesh"
                    }
                } label: {
                    Label("Share over the mesh", systemImage: "dot.radiowaves.left.and.right")
                }
                Button {
                    Task {
                        await classic.resetPath(to: contact)
                        actionNote = "Route reset — the radio will re-discover the path"
                    }
                } label: {
                    Label("Reset routing path", systemImage: "arrow.triangle.2.circlepath")
                }
                if let actionNote {
                    Label(actionNote, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Share & routing")
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
        .sheet(isPresented: $showCardQR) {
            ContactQRSheet(contact: contact)
        }
        .sheet(isPresented: $showTelemetry) {
            TelemetrySheet(contact: contact)
        }
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

    // MARK: - Contact QR sheet

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
        } header: {
            Text("Repeater access")
        } footer: {
            Text("Leave the password blank for repeaters configured with open guest access.")
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

/// A contact's shareable QR code.
/// Telemetry for one node, presented as its own page the moment a request
/// goes out — so you watch the reply land instead of hunting for it inline.
struct TelemetrySheet: View {
    @EnvironmentObject private var classic: ClassicStore
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let contact: MeshCore.Contact

    private var prefixHex: String { contact.publicKey.prefix(6).hexEncoded }
    private var readings: [CayenneLPP.Reading] { classic.telemetry[prefixHex] ?? [] }

    /// Nothing back yet, and we asked recently enough to still be hopeful.
    @State private var waiting = true

    var body: some View {
        NavigationStack {
            Group {
                if !readings.isEmpty {
                    List {
                        Section {
                            ForEach(readings) { reading in
                                LabeledContent(reading.label, value: reading.value)
                            }
                        } header: {
                            Text("Readings")
                        } footer: {
                            Text("Reported by \(contact.name.isEmpty ? "this node" : contact.name) over the mesh. Values are whatever sensors that device exposes.")
                        }
                    }
                } else if waiting {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Waiting for a reply over the mesh…")
                            .foregroundStyle(.secondary)
                        Text("LoRa round trips can take a while, and the node may be several hops away or asleep.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    EmptyStateView(systemImage: "waveform.path.ecg",
                                   title: "No telemetry",
                                   message: "That node didn't answer. It may be out of range, asleep, or not sharing telemetry.")
                }
            }
            .navigationTitle(contact.name.isEmpty ? "Telemetry" : contact.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        waiting = true
                        Task { await classic.requestTelemetry(contact: contact) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!app.transportState.isConnected)
                    .accessibilityLabel("Request again")
                }
            }
            .task {
                // Give the mesh a realistic window before calling it a miss.
                waiting = readings.isEmpty
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if readings.isEmpty { waiting = false }
            }
        }
    }
}

struct ContactQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contact: MeshCore.Contact

    private var code: String { ContactCard.encode(contact) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let image = QRSupport.generate(from: code) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .padding(10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text(contact.name.isEmpty ? "Node" : contact.name)
                        .font(.headline)
                    Text("Scan this in person, or send the code below to save this node on another device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    ContactCodeActions(code: code, subject: contact.name.isEmpty ? "Node" : contact.name)
                }
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
            .navigationTitle("Share contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Copy / share / show-the-raw-text actions for a contact card. A QR alone
/// only works face to face — these give the code somewhere to actually go.
struct ContactCodeActions: View {
    let code: String
    let subject: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy code",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                ShareLink(item: code, subject: Text(subject),
                          message: Text("Add this MeshCore contact in Fellship: Nodes → ⋯ → Add contact by code")) {
                    Label("Send", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
            Text(code)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}
