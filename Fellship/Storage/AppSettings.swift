import Foundation
import SwiftUI

/// Which base map the user renders. The custom option points MapLibre at a
/// user-supplied tile URL; the key/token embedded in it lives only in the
/// user's Keychain (spec §7).
enum TileSourceKind: String, CaseIterable, Identifiable, Codable {
    case openStreetMap
    case nasaSatellite
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openStreetMap: return "OpenStreetMap"
        case .nasaSatellite: return "NASA satellite"
        case .custom: return "Custom provider"
        }
    }
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
    static let donationCryptoAddress = "85f9zpwoRWbaZsZToh44Aei9qohnEVS6KB8yjjQRbmvUEUKkYnD5jvy368xTjHgbRq7DvbpXz3xgmaqaCR6hCxLnA8B3k3A"

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.double(forKey: "updateInterval")
        updateIntervalSeconds = storedInterval == 0 ? 60 : storedInterval
        publicRoomAlerts = defaults.bool(forKey: "publicRoomAlerts")
        tileSource = TileSourceKind(rawValue: defaults.string(forKey: "tileSource") ?? "") ?? .openStreetMap
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
    }
}
