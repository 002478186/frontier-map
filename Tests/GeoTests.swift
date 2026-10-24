import XCTest
import CoreLocation
@testable import FrontierMap

final class GeoTests: XCTestCase {
    private let origin = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    func testBearingCardinals() {
        XCTAssertEqual(Geo.bearing(from: origin, to: .init(latitude: 1, longitude: 0)), 0, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: origin, to: .init(latitude: 0, longitude: 1)), 90, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: origin, to: .init(latitude: -1, longitude: 0)), 180, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: origin, to: .init(latitude: 0, longitude: -1)), 270, accuracy: 0.01)
    }

    func testCompassPointWrapsAround() {
        XCTAssertEqual(Geo.compassPoint(359), "north")
        XCTAssertEqual(Geo.compassPoint(44), "northeast")
        XCTAssertEqual(Geo.compassPoint(200), "south")
        XCTAssertEqual(Geo.compassPoint(300), "northwest")
    }

    func testWaypointRoundTrip() throws {
        let w = [Waypoint(name: "Camp", lat: 36.1, lon: -112.1)]
        XCTAssertEqual(try JSONDecoder().decode([Waypoint].self, from: JSONEncoder().encode(w)), w)
    }
}
