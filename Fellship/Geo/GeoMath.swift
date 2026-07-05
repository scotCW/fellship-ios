import Foundation

/// Pure geographic math. No CoreLocation, fully unit-testable.
enum GeoMath {
    static let earthRadiusMeters = 6_371_000.0

    /// Great-circle distance in meters (haversine).
    static func distanceMeters(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `from` to `to`, degrees 0..<360 clockwise from north.
    static func bearingDegrees(from: Coordinate, to: Coordinate) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Containment

    static func contains(_ boundary: Boundary, point: Coordinate) -> Bool {
        switch boundary {
        case .circle(let center, let radius):
            return distanceMeters(center, point) <= radius
        case .box(let a, let b):
            return boxContains(cornerA: a, cornerB: b, point: point)
        case .polygon(let vertices):
            return polygonContains(vertices: vertices, point: point)
        }
    }

    static func boxContains(cornerA a: Coordinate, cornerB b: Coordinate, point p: Coordinate) -> Bool {
        let minLat = min(a.latitude, b.latitude)
        let maxLat = max(a.latitude, b.latitude)
        guard p.latitude >= minLat && p.latitude <= maxLat else { return false }

        // Longitude needs antimeridian awareness: pick the smaller of the two
        // spans the corners could describe.
        var lo = min(a.longitude, b.longitude)
        var hi = max(a.longitude, b.longitude)
        if hi - lo > 180 {
            // The box crosses the antimeridian; the "inside" is the wrap span.
            swap(&lo, &hi)
            return p.longitude >= lo || p.longitude <= hi
        }
        return p.longitude >= lo && p.longitude <= hi
    }

    /// Ray-casting point-in-polygon on the lat/lon plane. Appropriate for the
    /// zone sizes this app deals in (meters to a few km); not for
    /// continent-scale polygons.
    static func polygonContains(vertices: [Coordinate], point p: Coordinate) -> Bool {
        guard vertices.count >= 3 else { return false }
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let vi = vertices[i]
            let vj = vertices[j]
            if (vi.latitude > p.latitude) != (vj.latitude > p.latitude) {
                let t = (p.latitude - vi.latitude) / (vj.latitude - vi.latitude)
                let crossLon = vi.longitude + t * (vj.longitude - vi.longitude)
                if p.longitude < crossLon {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    // MARK: - Enclosing circle (for CoreLocation region monitoring)

    /// The smallest practical circle covering a boundary, used to register a
    /// CLCircularRegion that wakes the app near the zone.
    static func enclosingCircle(of boundary: Boundary) -> (center: Coordinate, radiusMeters: Double) {
        switch boundary {
        case .circle(let center, let radius):
            return (center, radius)
        case .box(let a, let b):
            let center = Coordinate(latitude: (a.latitude + b.latitude) / 2,
                                    longitude: midLongitude(a.longitude, b.longitude))
            let radius = distanceMeters(center, a)
            return (center, radius)
        case .polygon(let vertices):
            guard !vertices.isEmpty else { return (Coordinate(latitude: 0, longitude: 0), 0) }
            let center = centroid(of: vertices)
            let radius = vertices.map { distanceMeters(center, $0) }.max() ?? 0
            return (center, radius)
        }
    }

    static func centroid(of vertices: [Coordinate]) -> Coordinate {
        guard !vertices.isEmpty else { return Coordinate(latitude: 0, longitude: 0) }
        let lat = vertices.map(\.latitude).reduce(0, +) / Double(vertices.count)
        let lon = vertices.map(\.longitude).reduce(0, +) / Double(vertices.count)
        return Coordinate(latitude: lat, longitude: lon)
    }

    private static func midLongitude(_ a: Double, _ b: Double) -> Double {
        if abs(a - b) <= 180 { return (a + b) / 2 }
        // Antimeridian crossing: average on the wrapped circle.
        let mid = (a + b + 360) / 2
        return mid > 180 ? mid - 360 : mid
    }

    /// Approximates a circle as a polygon for map rendering. Latitudes are
    /// clamped to web-mercator's displayable range so continent-scale zones
    /// still render sanely; containment checks use exact haversine math and
    /// are unaffected by this display clamp.
    static func circlePolygon(center: Coordinate, radiusMeters: Double, segments: Int = 64) -> [Coordinate] {
        guard segments >= 3, radiusMeters > 0 else { return [] }
        let latRad = center.latitude * .pi / 180
        let dLat = radiusMeters / earthRadiusMeters * 180 / .pi
        let cosLat = max(0.000001, cos(latRad))
        let dLon = dLat / cosLat
        return (0..<segments).map { i in
            let theta = Double(i) / Double(segments) * 2 * .pi
            let lat = min(max(center.latitude + dLat * sin(theta), -85), 85)
            let lon = center.longitude + dLon * cos(theta)
            return Coordinate(latitude: lat, longitude: min(max(lon, -179.9), 179.9))
        }
    }
}
