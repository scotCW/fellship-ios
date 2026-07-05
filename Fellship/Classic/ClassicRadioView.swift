import SwiftUI

/// Radio management for classic mode: the shared pairing/dashboard plus
/// node tools (advert, rename, TX power).
struct ClassicRadioView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var newName = ""
    @State private var txPower: Double = 22
    @State private var toolFeedback: String?

    var body: some View {
        NavigationStack {
            List {
                // The full pairing UI / dashboard is shared with Fellship mode —
                // one radio, one connection.
                Section {
                    NavigationLink {
                        RadioView()
                    } label: {
                        HStack {
                            Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                            Spacer()
                            if case .connected(let name) = app.transportState {
                                Text(name).foregroundStyle(.secondary)
                            } else {
                                Text("Not connected").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if app.transportState.isConnected {
                    toolsSection
                }

                if let toolFeedback {
                    Section {
                        Label(toolFeedback, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Radio")
            .onAppear {
                if let info = app.selfInfo {
                    txPower = Double(info.txPower)
                }
            }
        }
    }

    private var toolsSection: some View {
        Section {
            Button {
                Task {
                    try? await app.session?.sendSelfAdvert(flood: false)
                    toolFeedback = "Advert sent (zero hop)"
                }
            } label: {
                Label("Send advert (zero hop)", systemImage: "dot.radiowaves.right")
            }
            Button {
                Task {
                    try? await app.session?.sendSelfAdvert(flood: true)
                    toolFeedback = "Advert flooded across the mesh"
                }
            } label: {
                Label("Send advert (flood)", systemImage: "dot.radiowaves.left.and.right")
            }

            HStack {
                TextField("New radio name", text: $newName)
                Button("Rename") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        try? await app.session?.setAdvertName(name)
                        toolFeedback = "Radio renamed to “\(name)”"
                        newName = ""
                    }
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $txPower,
                       in: 1...Double(app.selfInfo?.maxTxPower ?? 30),
                       step: 1) { editing in
                    if !editing {
                        Task {
                            try? await app.session?.setTxPower(dBm: UInt8(txPower))
                            toolFeedback = "TX power set to \(Int(txPower)) dBm"
                        }
                    }
                }
                Text("TX power: \(Int(txPower)) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Node tools")
        } footer: {
            Text("These change settings on the radio itself. Higher TX power reaches further and drains the battery faster — stay within your region's legal limit.")
        }
    }
}
