import XCTest
import CoreLocation
@testable import FrontierMap

final class FeatureTests: XCTestCase {
    func testAssistantReadsRequests() {
        let loop = TripRequest.parse("Plan a 3-hour drive with a lunch stop and a lookout point")
        XCTAssertEqual(loop.hours, 3)
        XCTAssertNil(loop.destination)
        XCTAssertEqual(loop.stops, [.food, .lookout])
        XCTAssertEqual(loop.travel, .car)

        let commute = TripRequest.parse("Find a quiet coffee shop on my way to work")
        XCTAssertEqual(commute.destination, "work")
        XCTAssertEqual(commute.stops, [.coffee]) // not also "shop"

        XCTAssertEqual(TripRequest.parse("take me to the beach").destination, "beach")
        XCTAssertEqual(TripRequest.parse("take me to the beach").stops, [])
        XCTAssertEqual(TripRequest.parse("2 hours bike ride with coffee").hours, 2)
        XCTAssertEqual(TripRequest.parse("2 hours bike ride with coffee").travel, .bike)
        XCTAssertEqual(TripRequest.parse("half an hour walk").hours, 0.5)
        XCTAssertEqual(TripRequest.parse("90 minute drive").hours, 1.5)
        XCTAssertNil(TripRequest.parse("somewhere to eat").destination)    // "to eat" isn't a place
        XCTAssertEqual(TripRequest.parse("somewhere to eat").stops, [.food])
        XCTAssertEqual(TripRequest.parse("a great theatre").stops, [])      // "eat" only at the start of a word
    }

    private func fix(_ lon: Double, _ t: TimeInterval) -> CLLocation {
        CLLocation(coordinate: .init(latitude: 0, longitude: lon), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                   timestamp: Date(timeIntervalSince1970: t))
    }

    func testTripRecorderStartsMovingAndEndsStill() {
        var r = TripRecorder()
        XCTAssertNil(r.update(fix(0, 0), name: "Free ride"))
        XCTAssertNil(r.update(fix(0.001, 10), name: "Free ride")) // ~110 m: not a trip yet
        XCTAssertNil(r.current)
        XCTAssertNil(r.update(fix(0.003, 30), name: "Free ride")) // ~330 m: trip starts
        XCTAssertNotNil(r.current)
        XCTAssertNil(r.update(fix(0.01, 90), name: "Free ride"))
        XCTAssertNil(r.update(fix(0.01, 100), name: "Free ride"))    // stopped
        let trip = r.update(fix(0.01, 300), name: "Free ride")      // still for over 3 minutes
        XCTAssertEqual(trip?.distance ?? 0, 1113, accuracy: 20)
        XCTAssertNil(r.current)
    }

    func testFogCells() {
        var e = Explorer()
        let c = CLLocationCoordinate2D(latitude: 12.97, longitude: 77.59)
        let center = Explorer.center(Explorer.key(c))
        XCTAssertEqual(center.latitude, c.latitude, accuracy: Explorer.cell)
        XCTAssertEqual(center.longitude, c.longitude, accuracy: Explorer.cell)
        XCTAssertTrue(e.visit(c))
        XCTAssertFalse(e.visit(c)) // nothing new the second time
        XCTAssertEqual(e.cells.count, 9)
        XCTAssertEqual(e.area, 9 * 0.2226 * 0.2226 * cos(12.97 * .pi / 180), accuracy: 0.01)
        XCTAssertEqual(e.cells(sw: .init(latitude: 12.9, longitude: 77.5), ne: .init(latitude: 13, longitude: 77.6)).count, 9)
        XCTAssertEqual(e.cells(sw: .init(latitude: 0, longitude: 0), ne: .init(latitude: 1, longitude: 1)).count, 0)
    }

    func testSamplingAndBeeline() {
        let path = [CLLocationCoordinate2D(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01), .init(latitude: 0, longitude: 0.03)]
        let s = path.sampled(4)
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[1].longitude, 0.01, accuracy: 1e-6)
        XCTAssertEqual(s[3].longitude, 0.03, accuracy: 1e-6)

        let r = Route.beeline(from: path[0], to: Destination(name: "Camp", coordinate: path[2]), travel: .walk)
        XCTAssertTrue(r.beeline)
        XCTAssertEqual(r.steps.count, 2)
        XCTAssertEqual(r.distance, 3340, accuracy: 10)
        XCTAssertEqual(r.expectedTravelTime, r.distance / 1.3, accuracy: 1)
    }

    func testStopGoesWhereTheDetourIsShortest() {
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let stops = [CLLocationCoordinate2D(latitude: 0, longitude: 1), .init(latitude: 0, longitude: 2)]
        XCTAssertEqual(Geo.insertionIndex(of: .init(latitude: 0.01, longitude: 0.5), into: stops, from: start), 0)
        XCTAssertEqual(Geo.insertionIndex(of: .init(latitude: 0.01, longitude: 1.5), into: stops, from: start), 1)
        XCTAssertEqual(Geo.insertionIndex(of: .init(latitude: 0, longitude: 5), into: [], from: start), 0)
    }

    func testSpeedLimitTagsAndClimb() {
        XCTAssertEqual(SpeedLimit.kmh("50"), 50)
        XCTAssertEqual(SpeedLimit.kmh("30 mph")!, 48.28, accuracy: 0.01)
        XCTAssertNil(SpeedLimit.kmh("none"))
        XCTAssertNil(SpeedLimit.kmh("IN:urban"))
        let c = Elevation.climb([100, 150, 120, 200])
        XCTAssertEqual(c.up, 130)
        XCTAssertEqual(c.down, 30)
    }

    func testNightStyleIsDarkAndKeepsEveryColour() {
        let paper = MapStyle.night("#e6d3ab"), ink = MapStyle.night("#2e2014")
        let lightness = { (hex: String) in Double(Int(hex.dropFirst(), radix: 16)! >> 8 & 255) }
        XCTAssertLessThan(lightness(paper), 90)   // paper goes dark
        XCTAssertGreaterThan(lightness(ink), 170) // ink goes light
        let json = ##"{"a":"#e6d3ab","b":"#2e2014"}"##
        XCTAssertEqual(MapStyle.nightify(json), ##"{"a":"\##(paper)","b":"\##(ink)"}"##)
    }

    func testDarkBetweenSunsetAndSunrise() throws {
        let json = #"{"current":{"temperature_2m":20,"weather_code":0,"wind_speed_10m":5,"wind_direction_10m":0},"daily":{"sunrise":[1000,90000],"sunset":[50000,140000]}}"#
        let w = try JSONDecoder().decode(Weather.self, from: Data(json.utf8))
        XCTAssertTrue(w.isDark(now: Date(timeIntervalSince1970: 500)))
        XCTAssertFalse(w.isDark(now: Date(timeIntervalSince1970: 20000)))
        XCTAssertTrue(w.isDark(now: Date(timeIntervalSince1970: 60000)))
        XCTAssertFalse(w.isDark(now: Date(timeIntervalSince1970: 100000)))
    }

    func testAchievementsAndFamousRoads() {
        XCTAssertEqual(Achievement.famousRoad(in: "Turn right onto Mumbai Pune Expressway"), "mumbai pune expressway")
        XCTAssertNil(Achievement.famousRoad(in: "Turn left onto Main St"))
        var s = Stats()
        XCTAssertTrue(Achievement.all.allSatisfy { !$0.earned(s) })
        s.trips = 1
        s.found[.park] = 10
        let earned = Set(Achievement.all.filter { $0.earned(s) }.map(\.id))
        XCTAssertEqual(earned, ["first-ride", "parks-10"])
        XCTAssertEqual(Set(Achievement.all.map(\.id)).count, Achievement.all.count) // ids are unique
    }

    func testNewGuideLinesNameThePlace() {
        for r in Rider.allCases {
            XCTAssertTrue(r.discovered("Lalbagh").contains("Lalbagh"))
            XCTAssertTrue(r.achievement("Park Ranger").contains("Park Ranger"))
            XCTAssertTrue(r.slowDown("50 km/h").contains("50 km/h"))
        }
    }

    func testOldPinsGetEmptyNotes() throws {
        let old = #"[{"id":"9E3C2C34-6B8F-4C59-9A4B-2C1D9E0F1A2B","name":"Creek","lat":1,"lon":2,"kind":"camp"}]"#
        let w = try XCTUnwrap(JSONDecoder().decode([Waypoint].self, from: Data(old.utf8)).first)
        XCTAssertEqual(w.kind, .camp)
        XCTAssertEqual(w.note, "")
        XCTAssertNil(w.photo)
    }
}
