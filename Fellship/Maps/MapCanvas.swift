import SwiftUI
import MapLibre

/// A marker on the map.
struct MapMarker: Identifiable, Equatable {
    enum Kind: Equatable {
        case me
        case member
        case contact
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
    /// Points captured so far while tracing a freeform boundary.
    var draftPolygon: [Coordinate] = []
    /// Draft circle/box previews while creating a room.
    var draftBoundary: Boundary?
    /// When true, touches trace a polygon instead of panning the map.
    var isTracing = false
    var cameraTarget: CameraTarget?
    var onTracePoint: ((Coordinate) -> Void)?
    var onCameraIdle: ((Coordinate, Double) -> Void)?

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.showsUserLocation = false // Fellship draws its own position marker
        mapView.setCenter(CLLocationCoordinate2D(latitude: 37.77, longitude: -122.45),
                          zoomLevel: 11, animated: false)
        context.coordinator.mapView = mapView

        let trace = UIPanGestureRecognizer(target: context.coordinator,
                                           action: #selector(Coordinator.handleTrace(_:)))
        trace.maximumNumberOfTouches = 1
        trace.delegate = context.coordinator
        mapView.addGestureRecognizer(trace)
        context.coordinator.traceRecognizer = trace

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if coordinator.appliedStyleURL != styleURL {
            coordinator.appliedStyleURL = styleURL
            mapView.styleURL = styleURL
        }

        coordinator.traceRecognizer?.isEnabled = isTracing
        mapView.isScrollEnabled = !isTracing
        mapView.isRotateEnabled = !isTracing
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
        var traceRecognizer: UIPanGestureRecognizer?
        var appliedStyleURL: URL?
        var appliedCameraID: UUID?

        private var currentAnnotations: [MLNAnnotation] = []
        private var lastOverlayFingerprint: Int = 0
        private var markerKinds: [String: MapMarker.Kind] = [:] // keyed by marker title tag

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
            markerKinds.removeAll()

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

            for marker in markers {
                let point = MLNPointAnnotation()
                point.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude,
                                                          longitude: marker.coordinate.longitude)
                point.title = marker.name
                markerKinds[marker.name + "|" + marker.id] = marker.kind
                point.subtitle = marker.name + "|" + marker.id
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
            guard let point = annotation as? MLNPointAnnotation,
                  let tag = point.subtitle ?? point.title else { return nil }
            let kind = markerKinds[tag] ?? .member
            let name = point.title ?? "?"
            let reuseID = "marker-\(kind)-\(name)"
            if let existing = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseID) {
                return existing
            }
            let image = Self.markerImage(name: name, kind: kind)
            return MLNAnnotationImage(image: image, reuseIdentifier: reuseID)
        }

        static func markerImage(name: String, kind: MapMarker.Kind) -> UIImage {
            let size = CGSize(width: 34, height: 34)
            let renderer = UIGraphicsImageRenderer(size: size)
            let color: UIColor
            switch kind {
            case .me: color = .systemBlue
            case .member: color = .systemTeal
            case .contact: color = .systemOrange
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
            annotation is MLNPointAnnotation
        }

        // MARK: Camera reporting

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let center = mapView.centerCoordinate
            parent.onCameraIdle?(Coordinate(latitude: center.latitude, longitude: center.longitude),
                                 mapView.zoomLevel)
        }

        // MARK: Polygon tracing

        @objc func handleTrace(_ recognizer: UIPanGestureRecognizer) {
            guard parent.isTracing, let mapView else { return }
            switch recognizer.state {
            case .began, .changed:
                let point = recognizer.location(in: mapView)
                let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
                parent.onTracePoint?(Coordinate(latitude: coordinate.latitude,
                                                longitude: coordinate.longitude))
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}
