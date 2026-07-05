import SwiftUI
import MapLibre

/// A marker on the map.
struct MapMarker: Identifiable, Equatable {
    enum Kind: Equatable {
        case me
        case member
        case contact
        case vertex
    }

    var id: String
    var name: String
    var coordinate: Coordinate
    var kind: Kind
}

/// A room boundary drawn on the map.
struct MapBoundaryOverlay: Identifiable, Equatable {
    var id: String
    var boundary: Boundary
    var isActive: Bool
}

/// One-shot camera instruction; a new `id` triggers the move.
struct CameraTarget: Equatable {
    var id = UUID()
    var center: Coordinate
    var zoom: Double = 13
    var animated = true
}

/// SwiftUI wrapper around MLNMapView with everything Fellship needs:
/// boundaries, member markers, freeform-polygon capture, and camera control.
struct MapCanvas: UIViewRepresentable {
    var styleURL: URL
    var markers: [MapMarker] = []
    var boundaries: [MapBoundaryOverlay] = []
    /// Corners placed so far for an open (not yet closed) outline; rendered
    /// as straight connected segments with a dot at each corner.
    var draftPolygon: [Coordinate] = []
    /// Draft circle/box/closed-polygon previews while creating a room.
    var draftBoundary: Boundary?
    /// When true, single taps report a coordinate (corner placement).
    var tapToPlaceEnabled = false
    var cameraTarget: CameraTarget?
    var onMapTap: ((Coordinate) -> Void)?
    var onCameraIdle: ((Coordinate, Double) -> Void)?

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.showsUserLocation = false // Fellship draws its own position marker
        mapView.setCenter(CLLocationCoordinate2D(latitude: 37.77, longitude: -122.45),
                          zoomLevel: 11, animated: false)
        context.coordinator.mapView = mapView
        context.coordinator.appliedStyleURL = styleURL

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTapsRequired = 1
        // Don't steal MapLibre's double-tap zoom: our single tap waits for
        // any built-in double-tap to fail first.
        for recognizer in mapView.gestureRecognizers ?? [] {
            if let existingTap = recognizer as? UITapGestureRecognizer,
               existingTap.numberOfTapsRequired == 2 {
                tap.require(toFail: existingTap)
            }
        }
        mapView.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.appliedStyleURL != styleURL {
            coordinator.appliedStyleURL = styleURL
            mapView.styleURL = styleURL
        }

        coordinator.tapRecognizer?.isEnabled = tapToPlaceEnabled
        mapView.isPitchEnabled = false

        if let target = cameraTarget, coordinator.appliedCameraID != target.id {
            coordinator.appliedCameraID = target.id
            mapView.setCenter(CLLocationCoordinate2D(latitude: target.center.latitude,
                                                     longitude: target.center.longitude),
                              zoomLevel: target.zoom, animated: target.animated)
        }

        coordinator.syncOverlays(on: mapView,
                                 markers: markers,
                                 boundaries: boundaries,
                                 draftPolygon: draftPolygon,
                                 draftBoundary: draftBoundary)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapCanvas
        weak var mapView: MLNMapView?
        var tapRecognizer: UITapGestureRecognizer?
        var appliedStyleURL: URL?
        var appliedCameraID: UUID?

        /// Point annotation that carries its marker kind, so styling doesn't
        /// have to abuse title/subtitle fields.
        final class FellshipPointAnnotation: MLNPointAnnotation {
            var kind: MapMarker.Kind = .member
        }

        private var currentAnnotations: [MLNAnnotation] = []
        private var lastOverlayFingerprint: Int = 0

        init(parent: MapCanvas) {
            self.parent = parent
        }

        // MARK: Overlay sync

        func syncOverlays(on mapView: MLNMapView,
                          markers: [MapMarker],
                          boundaries: [MapBoundaryOverlay],
                          draftPolygon: [Coordinate],
                          draftBoundary: Boundary?) {
            var hasher = Hasher()
            markers.forEach { hasher.combine($0.id); hasher.combine($0.coordinate); hasher.combine($0.name) }
            boundaries.forEach { hasher.combine($0.id); hasher.combine($0.boundary); hasher.combine($0.isActive) }
            draftPolygon.forEach { hasher.combine($0) }
            if let draftBoundary { hasher.combine(draftBoundary) }
            let fingerprint = hasher.finalize()
            guard fingerprint != lastOverlayFingerprint else { return }
            lastOverlayFingerprint = fingerprint

            if !currentAnnotations.isEmpty {
                mapView.removeAnnotations(currentAnnotations)
                currentAnnotations.removeAll()
            }

            for overlay in boundaries {
                let shape = Self.shape(for: overlay.boundary, identifier: overlay.id,
                                       active: overlay.isActive)
                mapView.addAnnotation(shape)
                currentAnnotations.append(shape)
            }

            if let draftBoundary {
                let shape = Self.shape(for: draftBoundary, identifier: "draft", active: true)
                mapView.addAnnotation(shape)
                currentAnnotations.append(shape)
            }

            if draftPolygon.count >= 2 {
                var coords = draftPolygon.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let line = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                line.title = "draft-line"
                mapView.addAnnotation(line)
                currentAnnotations.append(line)
            }

            // A dot on every placed corner of an open outline.
            for vertex in draftPolygon {
                let dot = FellshipPointAnnotation()
                dot.coordinate = CLLocationCoordinate2D(latitude: vertex.latitude,
                                                        longitude: vertex.longitude)
                dot.kind = .vertex
                mapView.addAnnotation(dot)
                currentAnnotations.append(dot)
            }

            for marker in markers {
                let point = FellshipPointAnnotation()
                point.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude,
                                                          longitude: marker.coordinate.longitude)
                point.title = marker.name
                point.kind = marker.kind
                mapView.addAnnotation(point)
                currentAnnotations.append(point)
            }
        }

        private static func shape(for boundary: Boundary, identifier: String, active: Bool) -> MLNShape {
            let coordinates: [Coordinate]
            switch boundary {
            case .circle(let center, let radius):
                coordinates = GeoMath.circlePolygon(center: center, radiusMeters: radius)
            case .box(let a, let b):
                coordinates = [
                    a,
                    Coordinate(latitude: a.latitude, longitude: b.longitude),
                    b,
                    Coordinate(latitude: b.latitude, longitude: a.longitude),
                ]
            case .polygon(let vertices):
                coordinates = vertices
            }
            var coords = coordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            guard !coords.isEmpty else {
                return MLNPolygon(coordinates: &coords, count: 0)
            }
            let polygon = MLNPolygon(coordinates: &coords, count: UInt(coords.count))
            polygon.title = active ? "active" : "inactive"
            return polygon
        }

        // MARK: Shape styling

        func mapView(_ mapView: MLNMapView, fillColorForPolygonAnnotation annotation: MLNPolygon) -> UIColor {
            annotation.title == "active"
                ? UIColor.systemTeal.withAlphaComponent(0.18)
                : UIColor.systemGray.withAlphaComponent(0.12)
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation.title == "draft-line" { return .systemOrange }
            return annotation.title == "active" ? .systemTeal : .systemGray
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            3
        }

        func mapView(_ mapView: MLNMapView, alphaForShapeAnnotation annotation: MLNShape) -> CGFloat {
            1
        }

        // MARK: Marker images

        func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            guard let point = annotation as? FellshipPointAnnotation else { return nil }
            let kind = point.kind
            let name = point.title ?? "?"
            let reuseID = "marker-\(kind)-\(name)"
            if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseID) {
                return existing
            }
            let image = Self.markerImage(name: name, kind: kind)
            return MLNAnnotationImage(image: image, reuseIdentifier: reuseID)
        }

        static func markerImage(name: String, kind: MapMarker.Kind) -> UIImage {
            if kind == .vertex {
                // Small corner dot for the outline editor.
                let size = CGSize(width: 14, height: 14)
                return UIGraphicsImageRenderer(size: size).image { ctx in
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                    ctx.cgContext.setFillColor(UIColor.systemOrange.cgColor)
                    ctx.cgContext.fillEllipse(in: rect)
                    ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
                    ctx.cgContext.setLineWidth(1.5)
                    ctx.cgContext.strokeEllipse(in: rect)
                }
            }
            let size = CGSize(width: 34, height: 34)
            let renderer = UIGraphicsImageRenderer(size: size)
            let color: UIColor
            switch kind {
            case .me: color = .systemBlue
            case .member: color = .systemTeal
            case .contact: color = .systemOrange
            case .vertex: color = .systemOrange // unreachable; handled above
            }
            let initial = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
            return renderer.image { ctx in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                ctx.cgContext.setFillColor(color.cgColor)
                ctx.cgContext.fillEllipse(in: rect)
                ctx.cgContext.setStrokeColor(UIColor.white.cgColor)
                ctx.cgContext.setLineWidth(2.5)
                ctx.cgContext.strokeEllipse(in: rect)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                    .foregroundColor: UIColor.white,
                ]
                let text = NSAttributedString(string: initial, attributes: attrs)
                let textSize = text.size()
                text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                      y: (size.height - textSize.height) / 2))
            }
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            if let point = annotation as? FellshipPointAnnotation, point.kind == .vertex {
                return false // corner dots aren't tappable content
            }
            return annotation is MLNPointAnnotation
        }

        // MARK: Camera reporting

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            parent.onCameraIdle?(Coordinate(latitude: center.latitude, longitude: center.longitude),
                                 mapView.zoomLevel)
        }

        // MARK: Corner placement

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard parent.tapToPlaceEnabled, recognizer.state == .ended, let mapView else { return }
            let point = recognizer.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            parent.onMapTap?(Coordinate(latitude: coordinate.latitude,
                                        longitude: coordinate.longitude))
        }
    }
}
