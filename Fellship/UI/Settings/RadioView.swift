import SwiftUI

/// Radio pairing + live dashboard. Works with any board running stock
/// MeshCore companion firmware — nothing here is hardware-specific.
struct RadioView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var isScanning = false

    var body: some View {
        List {
            switch app.transportState {
            case .connected(let name):
                connectedSections(name: name)
            default:
                pairingSections
            }
        }
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if isScanning {
                app.stopScanning()
                isScanning = false
            }
        }
    }

    // MARK: Pairing

    @ViewBuilder
    private var pairingSections: some View {
        Section {
            if let error = app.connectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button {
                if isScanning {
                    app.stopScanning()
                } else {
                    app.startScanning()
                }
                isScanning.toggle()
            } label: {
                if isScanning {
                    Label("Stop scanning", systemImage: "stop.circle")
                } else {
                    Label("Scan for radios", systemImage: "magnifyingglass")
                }
            }
        } footer: {
            Text("Power on your MeshCore radio and keep it near this phone. Any board running stock MeshCore companion firmware works — Heltec, T-Beam, RAK and others.")
        }

        if !app.radios.isEmpty {
            Section("Found") {
                ForEach(app.radios) { radio in
                    Button {
                        isScanning = false
                        Task { await app.connect(to: radio) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(radio.name).font(.headline)
                                Text("Signal \(radio.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.transportState == .connecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.teal)
                            }
                        }
                    }
                }
            }
        } else if isScanning {
            Section {
                HStack {
                    ProgressView()
                    Text("Listening for radios…").foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Connected dashboard

    @ViewBuilder
    private func connectedSections(name: String) -> some View {
        Section {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title)
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    if let info = app.deviceInfo {
                        Text("\(info.manufacturerModel) · fw v\(info.firmwareVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let mv = app.batteryMilliVolts {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label("\(Format.batteryPercent(milliVolts: mv))%",
                              systemImage: batterySymbol(percent: Format.batteryPercent(milliVolts: mv)))
                        Text(Format.voltage(milliVolts: mv))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }

        if let info = app.selfInfo {
            Section("Radio configuration") {
                LabeledContent("Name", value: info.name)
                LabeledContent("Frequency", value: String(format: "%.3f MHz", Double(info.radioFrequencyKHz) / 1000))
                LabeledContent("Bandwidth", value: String(format: "%.0f kHz", Double(info.radioBandwidthHz) / 1000))
                LabeledContent("Spreading factor", value: "SF\(info.spreadingFactor)")
                LabeledContent("TX power", value: "\(info.txPower) dBm")
                if info.advertCoordinate.isPlausible {
                    LabeledContent("Radio GPS", value: Format.coordinate(info.advertCoordinate))
                } else {
                    LabeledContent("Radio GPS") {
                        Text("No fix").foregroundStyle(.orange)
                    }
                }
            }
        }

        Section {
            Button(role: .destructive) {
                app.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } footer: {
            if settings.demoMode {
                Text("This is the simulated demo radio. Turn off demo mode in Settings to pair real hardware.")
            } else {
                Text("Fellship reconnects to this radio automatically next launch.")
            }
        }
    }

    private func batterySymbol(percent: Int) -> String {
        switch percent {
        case 80...: return "battery.100"
        case 55..<80: return "battery.75"
        case 30..<55: return "battery.50"
        case 10..<30: return "battery.25"
        default: return "battery.0"
        }
    }
}
