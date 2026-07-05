import SwiftUI
import UIKit

/// The global settings page — contents mandated by spec §9, plus donations
/// (§10) and the legal disclosures (§13).
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var notifications: NotificationService

    @State private var showCustomDisclaimer = false
    @State private var showDonationQR = false
    @State private var copiedDonationAddress = false
    @State private var customDraft = ""
    @State private var customDraftLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                radioSection
                locationSection
                zonesSection
                publicRoomsSection
                mapSection
                notificationSection
                appearanceSection
                backupSection
                donationSection
                aboutSection
            }
            .navigationTitle("Settings")
            .alert("Using your own map provider", isPresented: $showCustomDisclaimer) {
                Button("I understand") {
                    settings.customAPIDisclaimerShown = true
                    settings.customTileTemplate = customDraft
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(MapDisclaimers.customFull)
            }
            .sheet(isPresented: $showDonationQR) {
                DonationQRSheet()
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: Identity

    private var identitySection: some View {
        Section {
            TextField("Display name", text: $settings.displayName)
        } header: {
            Text("Your name")
        } footer: {
            Text("Shown to members of rooms you join. Stored only on this device.")
        }
    }

    // MARK: Radio

    private var radioSection: some View {
        Section("Radio") {
            NavigationLink {
                RadioView()
            } label: {
                HStack {
                    Label("MeshCore radio", systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    if case .connected(let name) = app.transportState {
                        Text(name).foregroundStyle(.secondary)
                    } else {
                        Text("Not connected").foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: Binding(
                get: { settings.demoMode },
                set: { on in
                    Task {
                        if on { await app.enableDemoMode() } else { app.disableDemoMode() }
                    }
                })) {
                Label("Demo mode", systemImage: "sparkles")
            }
        }
    }

    // MARK: Location (spec §9: interval slider + battery note, last update, source)

    private var locationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $settings.updateIntervalSeconds, in: 15...600, step: 15) {
                    Text("Update interval")
                } onEditingChanged: { editing in
                    if !editing { app.updateIntervalChanged() }
                }
                Text("Every \(Format.interval(settings.updateIntervalSeconds))")
                    .font(.callout.weight(.medium))
            }
            LabeledContent("Last location update") {
                Text(location.lastFix.map { Format.ago($0.timestamp) } ?? "No fix yet")
            }
            LabeledContent("GPS source") {
                Text(location.gpsSourceLabel)
            }
            if location.authorization == .notDetermined {
                Button("Allow location access") {
                    location.requestWhenInUseAuthorization()
                }
            } else if location.authorization != .authorizedAlways {
                Button("Enable background detection (Always)") {
                    location.requestAlwaysAuthorization()
                }
            }
        } header: {
            Text("Location updates")
        } footer: {
            Text("One global interval drives everything — presence, zone checks and public-room beacons all share a single GPS read. More frequent updates use noticeably more radio and phone battery. Background entry/exit detection is event-driven and fires shortly after a change, not instantly — that's an iOS platform behavior.")
        }
    }

    // MARK: Zones & units

    private var zonesSection: some View {
        Section {
            Picker("Units", selection: $settings.units) {
                ForEach(DistanceUnits.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: maxCircleBinding, in: 0...1)
                Text("Largest circle zone: \(Format.distance(settings.maxCircleRadiusMeters, units: settings.units)) radius")
                    .font(.callout.weight(.medium))
            }
        } header: {
            Text("Zones & units")
        } footer: {
            Text("Mesh networks can span enormous areas, so circle zones can too. This sets the top of the radius slider when drawing a circle — keep it small for precision, raise it (up to \(Format.distance(AppSettings.maxCircleRadiusCeilingMeters, units: settings.units))) when your network is huge.")
        }
    }

    /// Log-scale position binding for the max-circle ceiling (1 mi … 10,000 mi).
    private var maxCircleBinding: Binding<Double> {
        let floor: Double = 1609 // 1 mile
        let ceiling = AppSettings.maxCircleRadiusCeilingMeters
        return Binding(
            get: { LogScale.position(of: settings.maxCircleRadiusMeters, min: floor, max: ceiling) },
            set: { settings.maxCircleRadiusMeters = LogScale.value(at: $0, min: floor, max: ceiling) })
    }

    // MARK: Public rooms

    private var publicRoomsSection: some View {
        Section {
            Toggle("Alert me about public rooms to join", isOn: $settings.publicRoomAlerts)
        } footer: {
            Text("When on, your radio periodically announces that you're open to invites — including your current position — at the update interval above. Members of a nearby active public room can then send you an invite, which you can accept or ignore.")
        }
    }

    // MARK: Maps

    private var mapSection: some View {
        Section {
            Picker("Base map", selection: $settings.tileSource) {
                ForEach(TileSourceKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            if settings.tileSource == .nasaSatellite {
                Text(MapDisclaimers.nasaResolution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if settings.tileSource == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Tile URL template with {z}/{x}/{y} and your key",
                              text: $customDraft, axis: .vertical)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...4)
                        .onAppear {
                            if !customDraftLoaded {
                                customDraftLoaded = true
                                customDraft = settings.customTileTemplate
                            }
                        }
                    if customDraft != settings.customTileTemplate {
                        HStack {
                            Button("Save template") { commitCustomTemplate() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(!customDraft.isEmpty && !TileSourceResolver.isValidTemplate(customDraft))
                            if !customDraft.isEmpty && !TileSourceResolver.isValidTemplate(customDraft) {
                                Text("Needs {z}, {x} and {y} placeholders")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    // Persistent short disclaimer (spec §7.1).
                    Text(MapDisclaimers.customShort)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                OfflineMapsView()
            } label: {
                Label("Offline maps", systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Maps")
        }
    }

    private func commitCustomTemplate() {
        if settings.customAPIDisclaimerShown || customDraft.isEmpty {
            settings.customTileTemplate = customDraft
        } else {
            // First entry of a key: show the full disclaimer once before
            // storing anything (spec §7.1).
            showCustomDisclaimer = true
        }
    }

    // MARK: Notifications

    private var notificationSection: some View {
        Section {
            if notifications.authorized {
                Label("Notifications enabled", systemImage: "bell.badge")
                    .foregroundStyle(.secondary)
            } else {
                Button("Enable notifications") {
                    notifications.requestAuthorization()
                }
            }
        } footer: {
            Text("All notifications are generated on this device when it processes mesh events. There is no push server. Expect a short delay for background events.")
        }
    }

    // MARK: Backup (owner-approved: explicit, passphrase-encrypted, user-held)

    private var backupSection: some View {
        Section {
            NavigationLink {
                BackupView()
            } label: {
                Label("Back up & restore", systemImage: "externaldrive.badge.timemachine")
            }
        } footer: {
            Text("Export an encrypted file of your rooms, keys, contacts and messages to keep wherever you like. Backups are protected by a passphrase you choose — lose both phone and passphrase and the data is gone.")
        }
    }

    // MARK: Donations (spec §10 — no IAP, no payment plumbing, no server)

    private var donationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppSettings.donationCryptoCurrency)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(AppSettings.donationCryptoAddress)
                    .font(.caption2.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = AppSettings.donationCryptoAddress
                        copiedDonationAddress = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedDonationAddress = false
                        }
                    } label: {
                        Label(copiedDonationAddress ? "Copied" : "Copy address",
                              systemImage: copiedDonationAddress ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        showDonationQR = true
                    } label: {
                        Label("Show QR", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Label("Support this app", systemImage: "heart")
        } footer: {
            Text("Fellship is free, with no ads, no subscriptions and no server costs. If you'd like to support development, donations to this address are appreciated.")
        }
    }

    // MARK: Appearance (free themes, both modes)

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    HStack {
                        Circle().fill(theme.accent).frame(width: 14, height: 14)
                        Text(theme.displayName)
                    }
                    .tag(theme)
                }
            }
            Picker("Mode", selection: $settings.appearance) {
                ForEach(AppearanceOverride.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: About / legal (spec §13)

    private var aboutSection: some View {
        Section("About") {
            NavigationLink("Privacy & your data") {
                PrivacyDisclosureView()
            }
            LabeledContent("Version", value: Bundle.main.shortVersion)
        }
    }
}

struct PrivacyDisclosureView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your data stays with you")
                    .font(.title2.bold())
                Group {
                    bullet("No servers. Rooms, members, messages and keys exist only on members' devices and travel only radio-to-radio over the mesh.")
                    bullet("Location is collected from your radio's GPS (or this phone as fallback) and shared only inside rooms you've joined — and only when that room's location sharing is on. It is never uploaded anywhere.")
                    bullet("Deleting a room, or this app, permanently destroys its data on this device. There is no backup, no account, and no recovery. That's by design.")
                    bullet("Room traffic is encrypted with a per-room key that only members hold, on top of the mesh network's own transport encryption.")
                }
                Divider()
                Text("Not a safety device")
                    .font(.headline)
                Text("Fellship is not a certified safety, emergency or rescue tool. Mesh radio coverage is unpredictable, background detection lags, and messages can be lost. Never rely on it as your only lifeline — carry proper equipment for serious backcountry travel.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Full-size scannable donation address.
struct DonationQRSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = QRSupport.generate(from: AppSettings.donationCryptoAddress) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
                Text(AppSettings.donationCryptoCurrency)
                    .font(.headline)
                Text(AppSettings.donationCryptoAddress)
                    .font(.caption2.monospaced())
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Donate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
