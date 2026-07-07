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
    @State private var requestedTelemetry = false
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

/// A contact's shareable QR code.
struct ContactQRSheet: View {
    @Environment(\.dismiss) private var dismiss
    let contact: MeshCore.Contact

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = QRSupport.generate(from: ContactCard.encode(contact)) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    Text(contact.name.isEmpty ? "Node" : contact.name)
                        .font(.headline)
                    Text("Scan from Nodes → + → Add contact by code to save this node.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                Spacer()
            }
            .padding(.top, 28)
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
