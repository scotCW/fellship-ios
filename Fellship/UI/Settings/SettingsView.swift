import SwiftUI
import SafariServices

/// The global settings page — contents mandated by spec §9, plus donations
/// (§10) and the legal disclosures (§13).
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var notifications: NotificationService

    @State private var showCustomDisclaimer = false
    @State private var showDonation = false
    @State private var customDraft = ""
    @State private var customDraftLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                radioSection
                locationSection
                publicRoomsSection
                mapSection
                notificationSection
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
            .sheet(isPresented: $showDonation) {
                SafariView(url: URL(string: AppSettings.donationURLPlaceholder)!)
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

    // MARK: Donations (spec §10 — external link only, no IAP)

    private var donationSection: some View {
        Section {
            Button {
                showDonation = true
            } label: {
                Label("Support this app", systemImage: "heart")
            }
        } footer: {
            Text("Fellship is free, with no ads, no subscriptions and no server costs. If you'd like to support development, you can donate — the link opens in a browser.")
        }
    }

    // MARK: About / legal (spec §13)

    private var aboutSection: some View {
        Section("About") {
            NavigationLink("Privacy & your data") {
                PrivacyDisclosureView()
            }
            LabeledContent("Version", value: Bundle.main.shortVersion)
            Link("Source code & licenses",
                 destination: URL(string: "https://example.com/replace-with-your-repo")!)
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

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
