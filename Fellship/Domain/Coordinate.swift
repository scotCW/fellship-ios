import Foundation

/// A geographic coordinate, independent of CoreLocation so the domain layer
/// stays testable and platform-neutral.
struct Coordinate: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// MeshCore radios encode positions as microdegrees in signed 32-bit ints.
    init(microdegreesLat: Int32, microdegreesLon: Int32) {
        self.latitude = Double(microdegreesLat) / 1_000_000
        self.longitude = Double(microdegreesLon) / 1_000_000
    }

    var microdegreesLat: Int32 { Int32((latitude * 1_000_000).rounded()) }
    var microdegreesLon: Int32 { Int32((longitude * 1_000_000).rounded()) }

    var isPlausible: Bool {
        latitude >= -90 && latitude <= 90 &&
        longitude >= -180 && longitude <= 180 &&
        !(latitude == 0 && longitude == 0) // radios report 0,0 before first GPS fix
    }
}

/// A location fix together with where it came from and when.
struct LocationFix: Equatable, Sendable {
    enum Source: String, Sendable {
        case radio
        case phone
    }

    var coordinate: Coordinate
    var source: Source
    var timestamp: Date

    var age: TimeInterval { Date().timeIntervalSince(timestamp) }
}
