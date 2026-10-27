import XCTest
import CoreLocation
@testable import FrontierMap

final class StepTrackerTests: XCTestCase {
    // A road along the equator with turns every 0.01° of longitude (~1.1 km); Apple-style steps share end points.
    private func c(_ lon: Double, _ lat: Double = 0) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    private func at(_ lon: Double, _ lat: Double = 0) -> CLLocation { CLLocation(latitude: lat, longitude: lon) }
    private var steps: [[CLLocationCoordinate2D]] { [[c(0)], [c(0), c(0.01)], [c(0.01), c(0.02)], [c(0.02)]] }

    func testCallsEachTurnEarlyAndRightBeforeIt() {
        var t = StepTracker(steps: steps, walking: false)
        XCTAssertEqual(t.update(at(0)), [.reached(1)])        // "head east" begins where you stand
        XCTAssertEqual(t.update(at(0.005)), [])               // ~560 m out: quiet
        XCTAssertEqual(t.update(at(0.008)), [.prepare(2)])    // ~220 m: "In 200 m, turn…"
        XCTAssertEqual(t.update(at(0.0085)), [])              // not twice
        XCTAssertEqual(t.update(at(0.00978)), [.now(2)])      // ~25 m: "Now, turn…"
        XCTAssertEqual(t.update(at(0.0100)), [.reached(2)])
        XCTAssertEqual(t.toNext ?? 0, 1113, accuracy: 5)      // measured along the road
    }

    func testNeverNeedsToHitTheCornerExactly() {
        var t = StepTracker(steps: steps, walking: false)
        _ = t.update(at(0))
        // GPS 60 m off the road and never near the corner: the turn still counts as passed.
        XCTAssertEqual(t.update(at(0.012, 0.00054)), [.reached(2)])
        XCTAssertEqual(t.offBy, 60, accuracy: 2)
    }

    func testSkipsTurnsYouJumpedPast() {
        var t = StepTracker(steps: steps, walking: false)
        XCTAssertEqual(t.update(at(0.015)), [.reached(1), .reached(2)])
        XCTAssertEqual(t.next, 3)
    }

    func testOnlyTheRoadAheadIsLeft() {
        var t = StepTracker(steps: steps, walking: false)
        _ = t.update(at(0.015))
        XCTAssertEqual(t.remaining.count, 2)                  // where you are, then the end
        XCTAssertEqual(t.remaining[0].longitude, 0.015, accuracy: 1e-6)
    }

    func testWalkingUsesTighterDistances() {
        var t = StepTracker(steps: steps, walking: true)
        _ = t.update(at(0))
        XCTAssertEqual(t.update(at(0.008)), [])               // 220 m is too early on foot
        XCTAssertEqual(t.update(at(0.0095)), [.prepare(2)])   // ~55 m
        XCTAssertEqual(t.update(at(0.00985)), [.now(2)])      // ~17 m
    }

    func testFasterMeansEarlier() {
        var t = StepTracker(steps: steps, walking: false)
        _ = t.update(at(0))
        XCTAssertEqual(t.update(at(0.0095), speed: 25), [.now(2)]) // ~55 m out at 90 km/h
    }

    func testDurationText() {
        XCTAssertEqual(Guide.duration(30, spoken: true), "1 minute")    // never says "0 minutes"
        XCTAssertEqual(Guide.lowerFirst("Turn right"), "turn right")
    }

    func testEveryRiderNamesThePlace() {
        for r in Rider.allCases {
            // toward() picks a random line, so ask many times to cover every variant.
            for _ in 0..<50 { XCTAssertTrue(r.toward("Camp", "3 miles north").contains("Camp"), r.name) }
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
