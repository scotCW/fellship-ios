import Foundation

/// Resolves the user's tile-source choice into a MapLibre style URL.
/// Two options (spec §7): OpenStreetMap vector tiles (default, no key), or
/// the user's own provider.
enum TileSourceResolver {
    /// OpenFreeMap serves OpenStreetMap-based vector tiles free of charge,
    /// with no API key and no registration — which is what keeps the map
    /// default inside the "zero owner cost" constraint.
    static let openStreetMapStyle = URL(string: "https://tiles.openfreemap.org/styles/liberty")!

    static let osmAttribution = "© OpenFreeMap · © OpenMapTiles · © OpenStreetMap contributors"

    /// Builds a minimal MapLibre style JSON around a raster XYZ template and
    /// returns it as a file URL (MapLibre loads styles by URL).
    static func rasterStyleURL(template: String, maxZoom: Int, attribution: String,
                               cacheKey: String) -> URL? {
        let style: [String: Any] = [
            "version": 8,
            "sources": [
                "raster-tiles": [
                    "type": "raster",
                    "tiles": [template],
                    "tileSize": 256,
                    "maxzoom": maxZoom,
                    "attribution": attribution,
                ],
            ],
            "layers": [
                [
                    "id": "background",
                    "type": "background",
                    "paint": ["background-color": "#0b1720"],
                ],
                [
                    "id": "raster-layer",
                    "type": "raster",
                    "source": "raster-tiles",
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: style) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fellship-style-\(cacheKey).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The style URL for the current settings, plus the attribution line the
    /// map should display.
    static func resolve(kind: TileSourceKind, customTemplate: String) -> (style: URL, attribution: String) {
        switch kind {
        case .openStreetMap:
            return (openStreetMapStyle, osmAttribution)
        case .custom:
            let trimmed = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("{z}"), trimmed.contains("{x}"), trimmed.contains("{y}"),
                  let url = rasterStyleURL(template: trimmed, maxZoom: 19,
                                           attribution: "Tiles © your configured provider",
                                           cacheKey: "custom-\(stableHash(trimmed))") else {
                // Fall back to the default rather than rendering nothing.
                return (openStreetMapStyle, osmAttribution)
            }
            return (url, "Tiles © your configured provider")
        }
    }

    /// True when the template looks usable ({z}/{x}/{y} placeholders present).
    static func isValidTemplate(_ template: String) -> Bool {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("https://") || t.hasPrefix("http://"))
            && t.contains("{z}") && t.contains("{x}") && t.contains("{y}")
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}

/// Spec §7.1 — exact required wording.
enum MapDisclaimers {
    static let customFull = """
    Using your own map provider: Offline downloads and caching are subject to your \
    provider's terms of service. Some providers (including Mapbox) restrict or prohibit \
    storing their tiles outside their own SDK, even on paid plans. You're responsible for \
    your account and any usage charges or violations. We don't see, store, or bill against \
    your API key — it stays on your device.
    """

    static let customShort = """
    Your key stays on your device. Offline caching may violate your provider's terms — \
    you're responsible for your account.
    """
}
