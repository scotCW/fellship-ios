import Foundation
import SwiftUI

/// Which base map the user renders. The custom option points MapLibre at a
/// user-supplied tile URL; the key/token embedded in it lives only in the
/// user's Keychain (spec §7).
enum TileSourceKind: String, CaseIterable, Identifiable, Codable {
    case openStreetMap
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openStreetMap: return "OpenStreetMap"
        case .custom: return "Custom provider"
        }
    }

    /// Raw value of the retired NASA GIBS source. Its imagery was too coarse
    /// (~250 m/px) to be worth keeping; anyone still stored on it is migrated
    /// back to the default on next launch.
    static let retiredNASARawValue = "nasaSatellite"
}

/// App-wide accent themes. All free, forever — theming is not a thing anyone
/// should pay for.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case fell, ocean, ember, moss, violet, slate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fell: return "Fell Teal"
        case .ocean: return "Ocean"
        case .ember: return "Ember"
        case .moss: return "Moss"
        case .violet: return "Violet"
        case .slate: return "Slate"
        }
    }
}

enum AppearanceOverride: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

/// Who Fellship will hand telemetry to when it is asked.
///
/// Important scope note, reflected in the UI: this governs what *Fellship*
/// serves. Standard MeshCore telemetry is answered by the radio's own
/// firmware without consulting the phone, so setting this to "No one" does
/// not gag a radio that is configured to answer — that has to be turned off
/// on the device itself.
enum TelemetryAudience: String, CaseIterable, Identifiable, Codable {
    case everyone
    case contactsOnly
    case nobody

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .everyone: return "Anyone"
        case .contactsOnly: return "Saved contacts"
        case .nobody: return "No one"
        }
    }
}

enum DistanceUnits: String, CaseIterable, Identifiable, Codable {
    case imperial, metric
    var id: String { rawValue }
    var displayName: String { self == .metric ? "Kilometers" : "Miles (US)" }
}

/// Global app settings. Non-sensitive values live in UserDefaults; the custom
/// map URL template (which may contain the user's API key) lives in Keychain.
@MainActor
final class AppSettings: ObservableObject {
    /// Shown in Settings → Support this app, with tap-to-copy and a QR code.
    /// No payment plumbing, no server — just the owner's address (spec §10).
    static let donationCryptoCurrency = "Monero (XMR)"
    static let donationCryptoAddress = "89Ztm2qYsiBFNfBg4gPYTxBwmtYtmDveBUFV5UfCo8B2Uwv1EtnXM5DVjEnuwfgYXCL13YDQ8chD1hYVo7sKGb3gCDi1x5U"

    private let defaults: UserDefaults
    private let keychain = KeychainStore(service: "app.fellship.settings")
    private static let customTemplateKey = "map.custom.template"

    /// Global location update interval in seconds. One setting for
    /// everything; the shortest-need piggyback rule is implemented in
    /// LocationService (spec §4).
    @Published var updateIntervalSeconds: Double {
        didSet { defaults.set(updateIntervalSeconds, forKey: "updateInterval") }
    }

    /// "Alert me about public rooms to join" — global, not per-room (spec §3.3).
    @Published var publicRoomAlerts: Bool {
        didSet { defaults.set(publicRoomAlerts, forKey: "publicRoomAlerts") }
    }

    @Published var tileSource: TileSourceKind {
        didSet { defaults.set(tileSource.rawValue, forKey: "tileSource") }
    }

    /// User's own tile URL template, e.g. https://.../{z}/{x}/{y}.png?key=...
    /// Stored in Keychain because it usually embeds the user's API key.
    @Published var customTileTemplate: String {
        didSet {
            if customTileTemplate.isEmpty {
                keychain.delete(Self.customTemplateKey)
            } else {
                try? keychain.save(Data(customTileTemplate.utf8), for: Self.customTemplateKey)
            }
        }
    }

    /// Whether the one-time full custom-API disclaimer has been shown (spec §7.1).
    @Published var customAPIDisclaimerShown: Bool {
        didSet { defaults.set(customAPIDisclaimerShown, forKey: "customAPIDisclaimerShown") }
    }

    @Published var units: DistanceUnits {
        didSet { defaults.set(units.rawValue, forKey: "units") }
    }

    /// Upper bound of the circle-zone radius slider, in meters. Mesh networks
    /// can span enormous areas, but a slider spanning 10,000 miles would make
    /// a 1-mile circle impossible to set precisely — so the ceiling itself is
    /// the user's choice (default 10 mi, up to 10,000 mi).
    @Published var maxCircleRadiusMeters: Double {
        didSet { defaults.set(maxCircleRadiusMeters, forKey: "maxCircleRadius") }
    }

    static let minCircleRadiusMeters: Double = 50
    static let maxCircleRadiusCeilingMeters: Double = 16_093_440 // 10,000 mi

    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: "onboardingComplete") }
    }

    /// Demo mode runs the app against a simulated mesh so it can be explored
    /// with no radio hardware.
    @Published var demoMode: Bool {
        didSet { defaults.set(demoMode, forKey: "demoMode") }
    }

    @Published var displayName: String {
        didSet { defaults.set(displayName, forKey: "displayName") }
    }

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }

    @Published var appearance: AppearanceOverride {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }

    /// Which top-level mode is showing: Fellship rooms or classic MeshCore.
    @Published var activeMode: String {
        didSet { defaults.set(activeMode, forKey: "activeMode") }
    }

    /// Auto-reconnect target: the identifier of the last paired radio.
    @Published var lastRadioIdentifier: String? {
        didSet { defaults.set(lastRadioIdentifier, forKey: "lastRadioIdentifier") }
    }

    /// Who Fellship serves telemetry to. See `TelemetryAudience` for the
    /// (important) limits of what the app can actually enforce.
    @Published var telemetryAudience: TelemetryAudience {
        didSet { defaults.set(telemetryAudience.rawValue, forKey: "telemetryAudience") }
    }

    /// Height of the user's own antenna above ground, in meters — used by the
    /// Tools → Line of sight terrain profile.
    @Published var myAntennaHeightMeters: Double {
        didSet { defaults.set(myAntennaHeightMeters, forKey: "myAntennaHeightMeters") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.double(forKey: "updateInterval")
        updateIntervalSeconds = storedInterval == 0 ? 60 : storedInterval
        publicRoomAlerts = defaults.bool(forKey: "publicRoomAlerts")
        // A stored "nasaSatellite" no longer resolves, so it lands on the
        // default here — which is exactly the intended migration.
        tileSource = TileSourceKind(rawValue: defaults.string(forKey: "tileSource") ?? "") ?? .openStreetMap
        if defaults.string(forKey: "tileSource") == TileSourceKind.retiredNASARawValue {
            defaults.set(TileSourceKind.openStreetMap.rawValue, forKey: "tileSource")
        }
        customTileTemplate = keychain.load(Self.customTemplateKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        customAPIDisclaimerShown = defaults.bool(forKey: "customAPIDisclaimerShown")
        units = DistanceUnits(rawValue: defaults.string(forKey: "units") ?? "") ?? .imperial
        let storedMaxRadius = defaults.double(forKey: "maxCircleRadius")
        maxCircleRadiusMeters = storedMaxRadius > 0
            ? min(storedMaxRadius, Self.maxCircleRadiusCeilingMeters)
            : 16_093 // 10 miles
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        demoMode = defaults.bool(forKey: "demoMode")
        displayName = defaults.string(forKey: "displayName") ?? ""
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .fell
        appearance = AppearanceOverride(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        activeMode = defaults.string(forKey: "activeMode") ?? "fellship"
        lastRadioIdentifier = defaults.string(forKey: "lastRadioIdentifier")
        telemetryAudience = TelemetryAudience(rawValue: defaults.string(forKey: "telemetryAudience") ?? "")
            ?? .contactsOnly
        let storedAntennaHeight = defaults.double(forKey: "myAntennaHeightMeters")
        myAntennaHeightMeters = storedAntennaHeight > 0 ? storedAntennaHeight : 2
    }
}
