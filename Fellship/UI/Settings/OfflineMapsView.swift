import SwiftUI

/// Manage downloaded map regions and add new ones (spec §7: user picks a
/// region and zoom span; tiles cache on-device so offline maps still render).
struct OfflineMapsView: View {
    @EnvironmentObject private var offline: OfflineMapManager
    @State private var showPicker = false

    var body: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    Label("Download a region", systemImage: "plus.circle")
                }
            } footer: {
                Text("Downloaded tiles come from the currently selected base map. If you use a custom provider, offline caching may violate its terms — you're responsible for your account.")
            }

            if !offline.regions.isEmpty {
                Section("Saved regions") {
                    ForEach(offline.regions) { region in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(region.name).font(.headline)
                                Spacer()
                                Text(Format.bytes(Int64(region.completedBytes)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if region.isComplete {
                                Label("Ready for offline use", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                ProgressView(value: region.progressFraction)
                                Text("\(region.completedResources) of \(region.expectedResources) tiles")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            offline.remove(offline.regions[index])
                        }
                    }
                }
            }

            if let error = offline.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Offline maps")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            OfflineRegionPicker()
        }
        .onAppear { offline.reload() }
    }
}

/// Frame a region on the map, choose detail, download.
struct OfflineRegionPicker: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var offline: OfflineMapManager
    @EnvironmentObject private var location: LocationService
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var maxZoom: Double = 14
    @State private var visibleCenter: Coordinate?
    @State private var visibleZoom: Double = 11
    @State private var cameraTarget: CameraTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    MapCanvas(styleURL: app.mapStyle.style,
                              cameraTarget: cameraTarget,
                              onCameraIdle: { center, zoom in
                                  visibleCenter = center
                                  visibleZoom = zoom
                              })
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.orange, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(28)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 12) {
                    TextField("Region name (e.g. Cairngorms)", text: $name)
                        .textFieldStyle(.roundedBorder)
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $maxZoom, in: 10...16, step: 1)
                        HStack {
                            Text("Detail: zoom \(Int(maxZoom))")
                            Spacer()
                            Text(estimateLabel)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Button {
                        download()
                    } label: {
                        Text("Download framed area")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(visibleCenter == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(14)
                .background(.regularMaterial)
            }
            .navigationTitle("Download region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let fix = location.lastFix {
                    cameraTarget = CameraTarget(center: fix.coordinate, zoom: 11, animated: false)
                }
            }
        }
    }

    /// The framed area approximated from center + zoom (span of the visible
    /// viewport minus the dashed inset).
    private var framedBounds: (sw: Coordinate, ne: Coordinate)? {
        guard let center = visibleCenter else { return nil }
        // Rough degrees-per-screen at this zoom (360° spans 2^z tiles of 256px;
        // a phone viewport is ~1.5 tiles wide).
        let lonSpan = 360 / pow(2, visibleZoom) * 1.3
        let latSpan = lonSpan * 0.9
        return (Coordinate(latitude: center.latitude - latSpan / 2,
                           longitude: center.longitude - lonSpan / 2),
                Coordinate(latitude: center.latitude + latSpan / 2,
                           longitude: center.longitude + lonSpan / 2))
    }

    private var estimateLabel: String {
        guard let bounds = framedBounds else { return "" }
        let fromZoom = max(1, Int(visibleZoom.rounded()) - 1)
        let estimate = OfflineMapManager.estimate(southWest: bounds.sw, northEast: bounds.ne,
                                                  fromZoom: fromZoom, toZoom: Int(maxZoom))
        return "~\(estimate.tiles) tiles · \(Format.bytes(estimate.approxBytes))"
    }

    private func download() {
        guard let bounds = framedBounds else { return }
        let fromZoom = max(1, Int(visibleZoom.rounded()) - 1)
        offline.download(name: name.trimmingCharacters(in: .whitespaces),
                         styleURL: app.mapStyle.style,
                         southWest: bounds.sw,
                         northEast: bounds.ne,
                         fromZoom: Double(fromZoom),
                         toZoom: maxZoom)
        dismiss()
    }
}
