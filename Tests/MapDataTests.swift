import XCTest
@testable import FrontierMap

@MainActor
final class MapDataTests: XCTestCase {
    /// The Refresh map data button revalidates the cache and saved areas, then says so.
    func testRefreshMapDataFinishes() {
        let model = AppModel()
        model.refreshMapData()
        XCTAssertEqual(model.banner, "Checking for newer map data…")
        let done = expectation(description: "refreshed")
        func poll() {
            if model.banner?.hasPrefix("Map data refreshed") == true { return done.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
        wait(for: [done], timeout: 20)
    }
}
