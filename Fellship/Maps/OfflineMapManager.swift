import Foundation
import MapLibre

/// One downloaded offline region as shown in Settings.
struct OfflineRegion: Identifiable {
    var id: ObjectIdentifier
    var name: String
    var completedResources: UInt64
    var expectedResources: UInt64
    var completedBytes: UInt64
    var isComplete: Bool
    var pack: MLNOfflinePack

    var progressFraction: Double {
        guard expectedResources > 0 else { return 0 }
        return min(1, Double(completedResources) / Double(expectedResources))
    }
}

/// Wraps MapLibre's offline tile storage: the user picks a region and zoom
/// span, we download exactly those tiles for offline rendering (spec §7).
/// MapKit is deliberately not involved anywhere near tile caching.
@MainActor
final class OfflineMapManager: NSObject, ObservableObject {
    @Published private(set) var regions: [OfflineRegion] = []
    @Published var lastError: String?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(packProgressDidChange(_:)),
                                               name: NSNotification.Name.MLNOfflinePackProgressChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(packDidReceiveError(_:)),
                                               name: NSNotification.Name.MLNOfflinePackError,
                                               object: nil)
        reload()
    }

    func reload() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        for pack in packs where pack.state != .complete {
            // Packs restored at launch stay silent until asked; without this
            // an in-flight download shows 0% forever after a relaunch.
            pack.requestProgress()
        }
        regions = packs.map(Self.describe)
    }

    private static func describe(_ pack: MLNOfflinePack) -> OfflineRegion {
        var name = "Saved region"
        if let context = try? JSONSerialization.jsonObject(with: pack.context) as? [String: String],
           let stored = context["name"] {
            name = stored
        }
        let progress = pack.progress
        return OfflineRegion(id: ObjectIdentifier(pack),
                             name: name,
                             completedResources: progress.countOfResourcesCompleted,
                             expectedResources: progress.countOfResourcesExpected,
                             completedBytes: progress.countOfBytesCompleted,
                             isComplete: pack.state == .complete,
                             pack: pack)
    }

    /// Kicks off a download of the given bounds across a zoom span.
    func download(name: String, styleURL: URL,
                  southWest: Coordinate, northEast: Coordinate,
                  fromZoom: Double, toZoom: Double) {
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: southWest.latitude, longitude: southWest.longitude),
            ne: CLLocationCoordinate2D(latitude: northEast.latitude, longitude: northEast.longitude))
        let region = MLNTilePyramidOfflineRegion(styleURL: styleURL,
                                                 bounds: bounds,
                                                 fromZoomLevel: fromZoom,
                                                 toZoomLevel: toZoom)
        let context = (try? JSONSerialization.data(withJSONObject: ["name": name])) ?? Data()
        MLNOfflineStorage.shared.addPack(for: region, withContext: context) { [weak self] pack, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.lastError = error.localizedDescription
                    return
                }
                pack?.resume()
                self.reload()
            }
        }
    }

    func remove(_ region: OfflineRegion) {
        MLNOfflineStorage.shared.removePack(region.pack) { [weak self] error in
            Task { @MainActor in
                if let error { self?.lastError = error.localizedDescription }
                self?.reload()
            }
        }
    }

    /// Rough size estimate before downloading, so users know what they're in
    /// for. Tile counts are exact; bytes use a typical-average per tile.
    nonisolated static func estimate(southWest: Coordinate, northEast: Coordinate,
                         fromZoom: Int, toZoom: Int) -> (tiles: Int, approxBytes: Int64) {
        var total = 0
        for z in fromZoom...max(fromZoom, toZoom) {
            let n = pow(2.0, Double(z))
            let x1 = Int(floor((southWest.longitude + 180) / 360 * n))
            let x2 = Int(floor((northEast.longitude + 180) / 360 * n))
            let y1 = Self.tileY(latitude: northEast.latitude, n: n)
            let y2 = Self.tileY(latitude: southWest.latitude, n: n)
            let xs = abs(x2 - x1) + 1
            let ys = abs(y2 - y1) + 1
            total += xs * ys
        }
        // ~35 KB average per tile is a reasonable blend of vector and raster.
        return (total, Int64(total) * 35_000)
    }

    nonisolated private static func tileY(latitude: Double, n: Double) -> Int {
        let latRad = latitude * .pi / 180
        let clamped = min(max(latRad, -1.4844), 1.4844) // web-mercator limits
        return Int(floor((1 - log(tan(clamped) + 1 / cos(clamped)) / .pi) / 2 * n))
    }

    @objc private func packProgressDidChange(_ note: Notification) {
        Task { @MainActor in self.reload() }
    }

    @objc private func packDidReceiveError(_ note: Notification) {
        Task { @MainActor in
            if let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error {
                self.lastError = error.localizedDescription
            }
        }
    }
}
