import XCTest
import CoreLocation
import UIKit
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
        let w = [Waypoint(name: "Camp", lat: 36.1, lon: -112.1, kind: .camp)]
        XCTAssertEqual(try JSONDecoder().decode([Waypoint].self, from: JSONEncoder().encode(w)), w)
    }

    func testPinsSavedBeforeCategoriesStillLoad() throws {
        let old = #"[{"id":"9E3C2C34-6B8F-4C59-9A4B-2C1D9E0F1A2B","name":"Creek","lat":1,"lon":2}]"#
        let w = try JSONDecoder().decode([Waypoint].self, from: Data(old.utf8))
        XCTAssertEqual(w.first?.name, "Creek")
        XCTAssertEqual(w.first?.kind, .pin)
    }

    func testDistanceToPath() {
        let path = [CLLocationCoordinate2D(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01)] // ~1.1 km east
        XCTAssertEqual(Geo.distance(from: .init(latitude: 0.0005, longitude: 0.005), toPath: path), 55.7, accuracy: 1) // beside the middle
        XCTAssertEqual(Geo.distance(from: .init(latitude: 0, longitude: -0.001), toPath: path), 111.3, accuracy: 1) // before the start
        XCTAssertEqual(Geo.distance(from: origin, toPath: []), .infinity)
    }

    func testCrossingWordsAndTurnArrows() {
        XCTAssertEqual(Guide.crossingWord(in: "turn left onto hebbal flyover"), "flyover")
        XCTAssertEqual(Guide.crossingWord(in: "continue onto brooklyn bridge"), "bridge")
        XCTAssertNil(Guide.crossingWord(in: "turn right onto main st"))
        XCTAssertEqual(Guide.maneuverSymbol("Turn left onto Main St"), "arrow.turn.up.left")
        XCTAssertEqual(Guide.maneuverSymbol("Keep right at the fork"), "arrow.up.right")
        XCTAssertEqual(Guide.maneuverSymbol("Make a U-turn"), "arrow.uturn.down")
    }

    func testWeatherFromOpenMeteo() throws {
        let json = #"{"current":{"time":1793023200,"interval":900,"temperature_2m":21.6,"weather_code":95,"wind_speed_10m":30,"wind_direction_10m":270},"daily":{"time":[1,2],"sunrise":[1000,90000],"sunset":[50000,140000]}}"#
        let w = try JSONDecoder().decode(Weather.self, from: Data(json.utf8))
        XCTAssertEqual(w.sky, "Storm rollin' in")
        XCTAssertTrue(w.spoken(now: Date(timeIntervalSince1970: 2000)).contains("Strong wind from the west"))
        XCTAssertTrue(w.daylight(now: Date(timeIntervalSince1970: 2000)).hasPrefix("Sun sets"))
        XCTAssertTrue(w.daylight(now: Date(timeIntervalSince1970: 60000)).hasPrefix("Sunrise")) // after dark: tomorrow's
    }

    func testBundledFontLoads() {
        XCTAssertNotNil(UIFont(name: "ChineseRocks", size: 17), "CHINESER.TTF missing from UIAppFonts or the bundle")
    }

    func testEveryPinKindHasAGlyph() {
        for k in Waypoint.Kind.allCases { XCTAssertNotNil(UIImage(systemName: k.symbol), k.rawValue) }
    }
}
