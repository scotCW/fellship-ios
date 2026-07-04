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

enum DistanceUnits: String, CaseIterable, Identifiable, Codable {
    case metric, imperial
    var id: String { rawValue }
    var displayName: String { self == .metric ? "Metric" : "Imperial" }
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
        units = DistanceUnits(rawValue: defaults.string(forKey: "units") ?? "") ?? .metric
        onboardingComplete = defaults.bool(forKey: "onboardingComplete")
        demoMode = defaults.bool(forKey: "demoMode")
        displayName = defaults.string(forKey: "displayName") ?? ""
        lastRadioIdentifier = defaults.string(forKey: "lastRadioIdentifier")
    }
}
