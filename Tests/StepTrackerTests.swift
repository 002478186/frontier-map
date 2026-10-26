import XCTest
import CoreLocation
@testable import FrontierMap

final class StepTrackerTests: XCTestCase {
    // Turn points every 0.01° of longitude along the equator (~1.1 km apart).
    private func at(_ lon: Double) -> CLLocation { CLLocation(latitude: 0, longitude: lon) }

    func testAnnouncesOnceThenReachesEachTurn() {
        var tracker = StepTracker(points: [at(0), at(0.01), at(0.02)], walking: false)
        XCTAssertNil(tracker.update(at(0.005)))                         // ~550 m out: quiet
        XCTAssertEqual(tracker.update(at(0.008)), .approaching(1))      // ~220 m: announce
        XCTAssertNil(tracker.update(at(0.0085)))                        // don't repeat it
        XCTAssertEqual(tracker.update(at(0.0099)), .reached(1, announced: true))
        XCTAssertEqual(tracker.update(at(0.0199)), .reached(2, announced: false)) // jumped straight to it
        XCTAssertNil(tracker.update(at(0.03)))                          // route finished
    }

    func testWalkingUsesTighterDistances() {
        var tracker = StepTracker(points: [at(0), at(0.01)], walking: true)
        XCTAssertNil(tracker.update(at(0.008)))                         // 220 m is too early on foot
        XCTAssertEqual(tracker.update(at(0.0097)), .approaching(1))     // ~33 m
    }

    func testDurationText() {
        XCTAssertEqual(Guide.duration(30, spoken: true), "1 minute")    // never says "0 minutes"
        XCTAssertEqual(Guide.lowerFirst("Turn right"), "turn right")
    }

    func testEveryRiderNamesThePlace() {
        for r in Rider.allCases {
            for line in [r.start("Camp", "3 miles", "5 minutes", walking: true), r.toward("Camp", "3 miles north"),
                         r.standingOn("Camp"), r.arrived("Camp")] {
                XCTAssertTrue(line.contains("Camp"), "\(r.name): \(line)")
            }
        }
    }

    func testBundledKokoroLoadsAndSpeaks() throws {
        let kokoro = try XCTUnwrap(Kokoro(), "Kokoro model missing from the app bundle")
        for r in Rider.allCases {
            let buffer = try XCTUnwrap(kokoro.render("Camp lies north.", speaker: r.speaker, speed: r.speed))
            XCTAssertGreaterThan(Double(buffer.frameLength) / buffer.format.sampleRate, 0.5, r.name) // real speech, not a blip
        }
    }
}
