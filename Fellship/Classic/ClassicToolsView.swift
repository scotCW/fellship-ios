import SwiftUI

/// The Tools tab: radio management plus network diagnostics — stats, packet
/// monitor, trace path, line-of-sight estimate, and the remote CLI.
struct ClassicToolsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var newName = ""
    @State private var txPower: Double = 22
    @State private var toolFeedback: String?

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                if app.transportState.isConnected {
                    radioToolsSection
                }
                diagnosticsSection
                if let toolFeedback {
                    Section {
                        Label(toolFeedback, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Tools")
            .onAppear {
                if let info = app.selfInfo {
                    txPower = Double(info.txPower)
                }
            }
        }
    }

    private var connectionSection: some View {
        Section {
            NavigationLink {
                RadioView()
            } label: {
                HStack {
                    Label("Radio connection", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if case .connected(let name) = app.transportState {
                        Text(name).foregroundStyle(.secondary)
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var radioToolsSection: some View {
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
                Text("TX power: \(Int(txPower)) dBm — stay within your region's legal limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Radio tools")
        }
    }

    private var diagnosticsSection: some View {
        Section("Network diagnostics") {
            NavigationLink {
                RadioStatsView()
            } label: {
                Label("Radio statistics", systemImage: "chart.bar")
            }
            NavigationLink {
                PacketMonitorView()
            } label: {
                Label("Packet monitor", systemImage: "waveform.badge.magnifyingglass")
            }
            NavigationLink {
                TracePathView()
            } label: {
                Label("Trace path", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            NavigationLink {
                LineOfSightView()
            } label: {
                Label("Line of sight", systemImage: "eye")
            }
            NavigationLink {
                CLITerminalView()
            } label: {
                Label("Remote CLI", systemImage: "terminal")
            }
        }
    }
}

// MARK: - Radio statistics

struct RadioStatsView: View {
    @EnvironmentObject private var app: AppState
    @State private var core: MeshCore.StatsPayload?
    @State private var radio: MeshCore.StatsPayload?
    @State private var packets: MeshCore.StatsPayload?
    @State private var loading = false

    var body: some View {
        List {
            if case .core(let batteryMV, let uptime, let queue)? = core {
                Section("Node") {
                    LabeledContent("Battery", value: Format.voltage(milliVolts: batteryMV))
                    LabeledContent("Uptime", value: Format.interval(Double(uptime)))
                    LabeledContent("TX queue", value: "\(queue)")
                }
            }
            if case .radio(let noise, let rssi, let snr, let txAir, let rxAir)? = radio {
                Section("Radio") {
                    LabeledContent("Noise floor", value: "\(noise) dBm")
                    LabeledContent("Last RSSI", value: "\(rssi) dBm")
                    LabeledContent("Last SNR", value: String(format: "%.1f dB", snr))
                    LabeledContent("TX airtime", value: Format.interval(Double(txAir)))
                    LabeledContent("RX airtime", value: Format.interval(Double(rxAir)))
                }
            }
            if case .packets(let recv, let sent, let sentFlood, let sentDirect,
                             let recvFlood, let recvDirect, let errors)? = packets {
                Section("Packets") {
                    LabeledContent("Received", value: "\(recv)")
                    LabeledContent("Sent", value: "\(sent)")
                    LabeledContent("Sent flood / direct", value: "\(sentFlood) / \(sentDirect)")
                    LabeledContent("Received flood / direct", value: "\(recvFlood) / \(recvDirect)")
                    if let errors {
                        LabeledContent("Receive errors", value: "\(errors)")
                    }
                }
            }
            if core == nil && radio == nil && packets == nil && !loading {
                EmptyStateView(systemImage: "chart.bar",
                               title: "No stats yet",
                               message: app.transportState.isConnected
                                   ? "Pull to refresh."
                                   : "Connect a radio first.")
            }
        }
        .navigationTitle("Radio statistics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let session = app.session else { return }
        loading = true
        core = try? await session.getStats(.core)
        radio = try? await session.getStats(.radio)
        packets = try? await session.getStats(.packets)
        loading = false
    }
}

// MARK: - Packet monitor

struct PacketMonitorView: View {
    @EnvironmentObject private var classic: ClassicStore

    var body: some View {
        Group {
            if classic.packetLog.isEmpty {
                EmptyStateView(systemImage: "waveform.badge.magnifyingglass",
                               title: "Listening…",
                               message: "Every raw packet the radio hears shows up here with its signal quality.")
            } else {
                List(classic.packetLog) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(String(format: "SNR %.1f dB", row.entry.snr))
                                .foregroundStyle(row.entry.snr > 5 ? .green : (row.entry.snr > 0 ? .orange : .red))
                            Text("RSSI \(row.entry.rssi) dBm")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(row.receivedAt, style: .time)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.medium))
                        Text(row.entry.payload.hexEncoded)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Packet monitor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button {
                        classic.packetLogPaused.toggle()
                    } label: {
                        Image(systemName: classic.packetLogPaused ? "play.fill" : "pause.fill")
                    }
                    .accessibilityLabel(classic.packetLogPaused ? "Resume capture" : "Pause capture")
                    Button {
                        classic.clearPacketLog()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear log")
                }
            }
        }
    }
}

// MARK: - Trace path

struct TracePathView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var classic: ClassicStore

    @State private var selectedKey: Data?

    private var routedNodes: [MeshCore.Contact] {
        engine.nearbyContacts.filter { $0.outPathLength >= 0 }
    }

    var body: some View {
        List {
            Section {
                Picker("Destination", selection: $selectedKey) {
                    Text("Choose a node").tag(Data?.none)
                    ForEach(routedNodes, id: \.publicKey) { contact in
                        Text(contact.name.isEmpty
                             ? "Radio \(contact.publicKey.prefix(4).hexEncoded)"
                             : contact.name)
                            .tag(Optional(contact.publicKey))
                    }
                }
                Button {
                    guard let contact = routedNodes.first(where: { $0.publicKey == selectedKey }) else { return }
                    Task { await classic.tracePath(to: contact) }
                } label: {
                    Label("Run trace", systemImage: "play.circle")
                }
                .disabled(selectedKey == nil || classic.traceInFlight)
            } footer: {
                Text("Probes the route hop by hop and reports the signal quality at each repeater along the way.")
            }

            if classic.traceInFlight {
                Section {
                    HStack {
                        ProgressView()
                        Text("Tracing over the mesh…").foregroundStyle(.secondary)
                    }
                }
            }

            if let trace = classic.lastTrace {
                Section("Result") {
                    if trace.pathHashes.isEmpty {
                        Label("Direct — no repeaters between you", systemImage: "arrow.right")
                    } else {
                        ForEach(Array(trace.pathHashes.enumerated()), id: \.offset) { index, hash in
                            LabeledContent("Hop \(index + 1) · node \(String(format: "%02x", hash))") {
                                Text(String(format: "%.1f dB SNR",
                                            index < trace.pathSNRs.count ? trace.pathSNRs[index] : 0))
                                    .foregroundStyle(snrColor(index < trace.pathSNRs.count ? trace.pathSNRs[index] : 0))
                            }
                        }
                    }
                    LabeledContent("Final leg") {
                        Text(String(format: "%.1f dB SNR", trace.finalSNR))
                            .foregroundStyle(snrColor(trace.finalSNR))
                    }
                }
            }
        }
        .navigationTitle("Trace path")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func snrColor(_ snr: Double) -> Color {
        snr > 5 ? .green : (snr > 0 ? .orange : .red)
    }
}

// MARK: - Line of sight

struct LineOfSightView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var settings: AppSettings

    @State private var selectedKey: Data?

    private var positionedNodes: [MeshCore.Contact] {
        engine.nearbyContacts.filter { $0.coordinate.isPlausible }
    }

    var body: some View {
        List {
            Section {
                Picker("To node", selection: $selectedKey) {
                    Text("Choose a node").tag(Data?.none)
                    ForEach(positionedNodes, id: \.publicKey) { contact in
                        Text(contact.name.isEmpty
                             ? "Radio \(contact.publicKey.prefix(4).hexEncoded)"
                             : contact.name)
                            .tag(Optional(contact.publicKey))
                    }
                }
            } footer: {
                if location.lastFix == nil {
                    Text("Needs your own position — connect a radio or allow location.")
                }
            }

            if let contact = positionedNodes.first(where: { $0.publicKey == selectedKey }),
               let mine = location.lastFix?.coordinate {
                let distance = GeoMath.distanceMeters(mine, contact.coordinate)
                let bearing = GeoMath.bearingDegrees(from: mine, to: contact.coordinate)
                // Earth-curvature bulge at the midpoint of the path.
                let bulge = (distance * distance) / (8 * GeoMath.earthRadiusMeters)
                // 60% first-Fresnel-zone clearance at 910 MHz, midpoint.
                let fresnel60 = 0.6 * 8.657 * (distance / 1000 / 0.910).squareRoot()

                Section("Geometry") {
                    LabeledContent("Distance", value: Format.distance(distance, units: settings.units))
                    LabeledContent("Bearing", value: "\(Int(bearing.rounded()))°")
                    LabeledContent("Earth-curvature bulge (midpoint)",
                                   value: Format.distance(bulge, units: settings.units))
                    LabeledContent("60% Fresnel clearance needed",
                                   value: Format.distance(fresnel60, units: settings.units))
                }
                Section {
                    Text("Terrain is not included — a full line-of-sight profile needs elevation data, which requires an online elevation service. These figures assume smooth earth: your antennas together need to clear roughly the bulge plus the Fresnel figure above at the midpoint.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Line of sight")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Remote CLI

struct CLITerminalView: View {
    @EnvironmentObject private var engine: RoomEngine
    @EnvironmentObject private var classic: ClassicStore

    @State private var selectedKey: Data?
    @State private var command = ""
    @State private var lines: [RoomMessage] = []

    private var repeaters: [MeshCore.Contact] {
        engine.nearbyContacts.filter { $0.type == 2 }
    }

    private var selectedContact: MeshCore.Contact? {
        repeaters.first { $0.publicKey == selectedKey }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Repeater", selection: $selectedKey) {
                Text("Choose a repeater").tag(Data?.none)
                ForEach(repeaters, id: \.publicKey) { contact in
                    Text(contact.name).tag(Optional(contact.publicKey))
                }
            }
            .pickerStyle(.menu)
            .padding(.vertical, 4)

            if let contact = selectedContact {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(lines) { line in
                                Text(line.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(line.isFromMe ? Color.accentColor : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color(.secondarySystemBackground))
                    .onAppear { reload(contact, scroll: proxy) }
                    .onChange(of: classic.cliRevision) { reload(contact, scroll: proxy) }
                    .onChange(of: engine.chatRevision) { reload(contact, scroll: proxy) }
                    .onChange(of: selectedKey) { reload(contact, scroll: proxy) }
                }

                HStack(spacing: 8) {
                    Text(">")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                    TextField("command", text: $command)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { runCommand(contact) }
                    Button {
                        runCommand(contact)
                    } label: {
                        Image(systemName: "return")
                    }
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Run command")
                }
                .padding(10)
                .background(.bar)
            } else {
                EmptyStateView(systemImage: "terminal",
                               title: "Remote CLI",
                               message: repeaters.isEmpty
                                   ? "No repeaters heard yet."
                                   : "Pick a repeater to open its console. Log in from its Nodes page first.")
            }
        }
        .navigationTitle("Remote CLI")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reload(_ contact: MeshCore.Contact, scroll proxy: ScrollViewProxy) {
        lines = classic.consoleMessages(for: contact)
        if let last = lines.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func runCommand(_ contact: MeshCore.Contact) {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        command = ""
        Task { await classic.sendCommand(text, to: contact) }
    }
}
