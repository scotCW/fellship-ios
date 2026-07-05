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

    /// Snaps this coordinate to a grid of roughly `gridMeters`, so the value
    /// reveals an approximate area rather than an exact point. Used before
    /// putting a position into the unencrypted, mesh-wide "open to invite"
    /// advert — discovery only needs the neighborhood, not your doorstep.
    func coarsened(toMeters gridMeters: Double) -> Coordinate {
        guard gridMeters > 0 else { return self }
        let metersPerDegLat = 111_320.0
        let latGrid = gridMeters / metersPerDegLat
        let snappedLat = (latitude / latGrid).rounded() * latGrid
        // Derive the longitude grid from the *snapped* latitude so the result
        // is idempotent (re-coarsening a coarse point returns it unchanged).
        let cosLat = max(0.01, cos(snappedLat * .pi / 180))
        let lonGrid = gridMeters / (metersPerDegLat * cosLat)
        return Coordinate(latitude: snappedLat,
                          longitude: (longitude / lonGrid).rounded() * lonGrid)
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
