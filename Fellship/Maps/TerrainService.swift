import Foundation

/// Fetches ground elevation for a line-of-sight terrain profile. Uses
/// Open-Meteo's elevation API — free, keyless, no registration, worldwide
/// coverage from Copernicus DEM GLO-90 (90 m resolution) — the same
/// "zero owner cost" bar the map tile sources hold to (see TileSource.swift).
/// This is the only Tools feature that leaves the device: it sends the
/// sampled lat/lon pairs (nothing else) to open-meteo.com, and only when the
/// user opens the terrain profile.
///
/// Attribution (required — Open-Meteo's data is CC BY 4.0, and Copernicus
/// DEM requires its own notice when the data is adapted): both must be
/// credited wherever this data is shown. See `TerrainAttribution` below and
/// its use in LineOfSightView / ClassicAboutView.
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

enum TerrainAttribution {
    /// Open-Meteo's required CC BY 4.0 attribution line.
    static let openMeteo = "Elevation data by Open-Meteo.com (CC BY 4.0)"
    static let openMeteoURL = URL(string: "https://open-meteo.com")!

    /// Copernicus's mandated notice for adapted/modified WorldDEM-90 data
    /// (License for COP-DEM-GLO-90-F, Free & Open).
    static let copernicus = "Produced using Copernicus WorldDEM-90 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018, provided under COPERNICUS by the European Union and ESA; all rights reserved."
    static let copernicusURL = URL(string: "https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM")!
}
