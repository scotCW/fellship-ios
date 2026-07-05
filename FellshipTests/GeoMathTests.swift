import XCTest
@testable import Fellship

final class GeoMathTests: XCTestCase {
    // Golden Gate Park-ish reference points.
    let park = Coordinate(latitude: 37.7694, longitude: -122.4862)

    func testDistanceKnownValue() {
        // SF → LA is roughly 559 km.
        let sf = Coordinate(latitude: 37.7749, longitude: -122.4194)
        let la = Coordinate(latitude: 34.0522, longitude: -118.2437)
        let d = GeoMath.distanceMeters(sf, la)
        XCTAssertEqual(d, 559_000, accuracy: 10_000)
    }

    func testDistanceZero() {
        XCTAssertEqual(GeoMath.distanceMeters(park, park), 0, accuracy: 0.001)
    }

    func testBearingCardinalDirections() {
        let origin = Coordinate(latitude: 0, longitude: 0)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: Coordinate(latitude: 1, longitude: 0)), 0, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: Coordinate(latitude: 0, longitude: 1)), 90, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: Coordinate(latitude: -1, longitude: 0)), 180, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearingDegrees(from: origin, to: Coordinate(latitude: 0, longitude: -1)), 270, accuracy: 0.5)
    }

    func testCircleContainment() {
        let boundary = Boundary.circle(center: park, radiusMeters: 500)
        XCTAssertTrue(GeoMath.contains(boundary, point: park))
        // ~400 m east.
        let inside = Coordinate(latitude: park.latitude, longitude: park.longitude + 0.0045)
        XCTAssertTrue(GeoMath.contains(boundary, point: inside))
        // ~1.4 km east.
        let outside = Coordinate(latitude: park.latitude, longitude: park.longitude + 0.016)
        XCTAssertFalse(GeoMath.contains(boundary, point: outside))
    }

    func testBoxContainmentAnyCornerOrder() {
        let a = Coordinate(latitude: 37.78, longitude: -122.49)
        let b = Coordinate(latitude: 37.76, longitude: -122.47)
        let inside = Coordinate(latitude: 37.77, longitude: -122.48)
        let outside = Coordinate(latitude: 37.79, longitude: -122.48)
        XCTAssertTrue(GeoMath.boxContains(cornerA: a, cornerB: b, point: inside))
        XCTAssertTrue(GeoMath.boxContains(cornerA: b, cornerB: a, point: inside))
        XCTAssertFalse(GeoMath.boxContains(cornerA: a, cornerB: b, point: outside))
    }

    func testBoxAcrossAntimeridian() {
        // A box spanning 179°E … 179°W (Fiji-ish).
        let a = Coordinate(latitude: -17, longitude: 179)
        let b = Coordinate(latitude: -19, longitude: -179)
        XCTAssertTrue(GeoMath.boxContains(cornerA: a, cornerB: b,
                                          point: Coordinate(latitude: -18, longitude: 179.9)))
        XCTAssertTrue(GeoMath.boxContains(cornerA: a, cornerB: b,
                                          point: Coordinate(latitude: -18, longitude: -179.9)))
        XCTAssertFalse(GeoMath.boxContains(cornerA: a, cornerB: b,
                                           point: Coordinate(latitude: -18, longitude: 0)))
    }

    func testPolygonContainmentConcave() {
        // A "U" shape: the notch must be outside.
        let u: [Coordinate] = [
            Coordinate(latitude: 0, longitude: 0),
            Coordinate(latitude: 3, longitude: 0),
            Coordinate(latitude: 3, longitude: 1),
            Coordinate(latitude: 1, longitude: 1),
            Coordinate(latitude: 1, longitude: 2),
            Coordinate(latitude: 3, longitude: 2),
            Coordinate(latitude: 3, longitude: 3),
            Coordinate(latitude: 0, longitude: 3),
        ]
        XCTAssertTrue(GeoMath.polygonContains(vertices: u, point: Coordinate(latitude: 0.5, longitude: 1.5)))
        XCTAssertFalse(GeoMath.polygonContains(vertices: u, point: Coordinate(latitude: 2, longitude: 1.5)))
        XCTAssertTrue(GeoMath.polygonContains(vertices: u, point: Coordinate(latitude: 2, longitude: 0.5)))
        XCTAssertFalse(GeoMath.polygonContains(vertices: u, point: Coordinate(latitude: 5, longitude: 5)))
    }

    func testPolygonDegenerateIsNeverContaining() {
        XCTAssertFalse(GeoMath.polygonContains(vertices: [], point: park))
        XCTAssertFalse(GeoMath.polygonContains(vertices: [park, park], point: park))
    }

    func testEnclosingCircleCoversBoundary() {
        let box = Boundary.box(cornerA: Coordinate(latitude: 37.78, longitude: -122.49),
                               cornerB: Coordinate(latitude: 37.76, longitude: -122.47))
        let circle = GeoMath.enclosingCircle(of: box)
        // Every corner must fall inside the circle.
        for corner in [Coordinate(latitude: 37.78, longitude: -122.49),
                       Coordinate(latitude: 37.76, longitude: -122.47),
                       Coordinate(latitude: 37.78, longitude: -122.47),
                       Coordinate(latitude: 37.76, longitude: -122.49)] {
            XCTAssertLessThanOrEqual(GeoMath.distanceMeters(circle.center, corner),
                                     circle.radiusMeters * 1.001)
        }
    }

    func testCirclePolygonApproximation() {
        let points = GeoMath.circlePolygon(center: park, radiusMeters: 300, segments: 64)
        XCTAssertEqual(points.count, 64)
        for point in points {
            XCTAssertEqual(GeoMath.distanceMeters(park, point), 300, accuracy: 6)
        }
    }

    func testMicrodegreeRoundTrip() {
        let c = Coordinate(latitude: 37.769423, longitude: -122.486201)
        let restored = Coordinate(microdegreesLat: c.microdegreesLat,
                                  microdegreesLon: c.microdegreesLon)
        XCTAssertEqual(restored.latitude, c.latitude, accuracy: 0.000001)
        XCTAssertEqual(restored.longitude, c.longitude, accuracy: 0.000001)
    }

    func testPlausibility() {
        XCTAssertFalse(Coordinate(latitude: 0, longitude: 0).isPlausible)
        XCTAssertFalse(Coordinate(latitude: 91, longitude: 0).isPlausible)
        XCTAssertTrue(park.isPlausible)
    }

    func testCoarseningHidesExactPointButStaysNearby() {
        let exact = Coordinate(latitude: 37.769423, longitude: -122.486201)
        let coarse = exact.coarsened(toMeters: 250)
        // The coarsened point must not equal the exact one…
        XCTAssertNotEqual(coarse.latitude, exact.latitude)
        XCTAssertNotEqual(coarse.longitude, exact.longitude)
        // …but must stay within roughly one grid cell (protects the doorstep,
        // still useful for neighborhood-level discovery).
        XCTAssertLessThan(GeoMath.distanceMeters(exact, coarse), 260)
        // Two nearby exact points snap to the same cell — no exact-position
        // leakage through jitter.
        let jitter = Coordinate(latitude: 37.769430, longitude: -122.486190)
        XCTAssertEqual(exact.coarsened(toMeters: 250).latitude,
                       jitter.coarsened(toMeters: 250).latitude, accuracy: 1e-9)
    }

    func testCoarseningIsStableAndGridAligned() {
        // Snapping an already-snapped point returns the same point.
        let c = Coordinate(latitude: 51.5, longitude: -0.12).coarsened(toMeters: 250)
        XCTAssertEqual(c.latitude, c.coarsened(toMeters: 250).latitude, accuracy: 1e-9)
        XCTAssertEqual(c.longitude, c.coarsened(toMeters: 250).longitude, accuracy: 1e-9)
    }
}
