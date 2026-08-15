import Foundation

/// Fetches ground elevation for a line-of-sight terrain profile. Uses
/// Open-Meteo's elevation API — free, keyless, no registration, worldwide
/// SRTM-based coverage — the same "zero owner cost" bar the map tile
/// sources hold to (see TileSource.swift). This is the only Tools feature
/// that leaves the device: it sends the sampled lat/lon pairs (nothing else)
/// to open-meteo.com, and only when the user opens the terrain profile.
enum TerrainService {
    enum ServiceError: Error {
        case badResponse
    }

    private static let endpoint = "https://api.open-meteo.com/v1/elevation"

    struct Sample {
        let coordinate: Coordinate
        let elevationMeters: Double
    }

    /// Elevation at `sampleCount` evenly-spaced points along the great-circle
    /// path from `from` to `to` (inclusive of both ends), fetched in a single
    /// batched request.
    static func elevationProfile(from: Coordinate, to: Coordinate,
                                 sampleCount: Int = 24) async throws -> [Sample] {
        let count = max(2, sampleCount)
        let points = (0..<count).map { i -> Coordinate in
            GeoMath.intermediate(from: from, to: to, fraction: Double(i) / Double(count - 1))
        }
        let lats = points.map { String(format: "%.6f", $0.latitude) }.joined(separator: ",")
        let lons = points.map { String(format: "%.6f", $0.longitude) }.joined(separator: ",")
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: lats),
            URLQueryItem(name: "longitude", value: lons),
        ]
        guard let url = components.url else { throw ServiceError.badResponse }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.badResponse
        }
        struct Payload: Decodable { let elevation: [Double] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.elevation.count == points.count else { throw ServiceError.badResponse }
        return zip(points, payload.elevation).map { Sample(coordinate: $0, elevationMeters: $1) }
    }
}
