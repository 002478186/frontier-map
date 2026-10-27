import Foundation
import CoreLocation
import MapKit

/// Small JSON files in the app's Documents folder. History never leaves the phone.
enum Store {
    static func url(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        (try? Data(contentsOf: url(name))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    static func save<T: Encodable>(_ value: T, _ name: String) {
        try? JSONEncoder().encode(value).write(to: url(name), options: .atomic)
    }
}

/// A logged ride, for the Journal.
struct Trip: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date
    var distance: CLLocationDistance
    var path: [[Double]] // [lat, lon] about every 30 m

    var coordinates: [CLLocationCoordinate2D] { path.map { .init(latitude: $0[0], longitude: $0[1]) } }
}

/// Logs rides automatically: one starts once you're 200 m from where you were standing,
/// and ends after 3 minutes without moving (or when a route ends).
struct TripRecorder {
    private(set) var current: Trip?
    private var anchor: CLLocation?
    private var last: CLLocation?
    private var stillSince: Date?

    /// Feed every location fix. Returns a trip when one has just ended.
    mutating func update(_ loc: CLLocation, name: String) -> Trip? {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 50 else { return nil }
        guard var trip = current, let last else {
            if let anchor, loc.distance(from: anchor) > 200 {
                current = Trip(name: name, start: anchor.timestamp, end: loc.timestamp, distance: loc.distance(from: anchor),
                               path: [[anchor.coordinate.latitude, anchor.coordinate.longitude], [loc.coordinate.latitude, loc.coordinate.longitude]])
                self.last = loc
                self.anchor = nil
            } else if anchor == nil || loc.timestamp.timeIntervalSince(anchor!.timestamp) > 600 {
                anchor = loc // standing around: start measuring from here
            }
            return nil
        }
        let step = loc.distance(from: last)
        if step >= 30 {
            trip.path.append([loc.coordinate.latitude, loc.coordinate.longitude])
            trip.distance += step
            trip.end = loc.timestamp
            trip.name = name
            current = trip
            self.last = loc
            stillSince = nil
            return nil
        }
        if let since = stillSince, loc.timestamp.timeIntervalSince(since) > 180 { return finish() }
        if stillSince == nil { stillSince = loc.timestamp }
        return nil
    }

    /// Ends the current trip; nil if there wasn't one worth keeping (under 300 m).
    mutating func finish() -> Trip? {
        defer { current = nil; last = nil; anchor = nil; stillSince = nil }
        return current.flatMap { $0.distance >= 300 ? $0 : nil }
    }
}

/// Fog of war: the world is cut into cells of about 220 m, and every cell you pass near is revealed.
struct Explorer: Codable {
    static let cell = 0.002 // degrees
    private(set) var cells: Set<Int64> = []

    static func key(_ c: CLLocationCoordinate2D) -> Int64 {
        Int64(floor((c.latitude + 90) / cell)) * 1_000_000 + Int64(floor((c.longitude + 180) / cell))
    }

    static func center(_ key: Int64) -> CLLocationCoordinate2D {
        .init(latitude: (Double(key / 1_000_000) + 0.5) * cell - 90, longitude: (Double(key % 1_000_000) + 0.5) * cell - 180)
    }

    /// Reveals the cell you're in and its neighbours. True if anything new was revealed.
    mutating func visit(_ c: CLLocationCoordinate2D) -> Bool {
        let k = Self.key(c)
        var added = false
        for dy in -1...1 as ClosedRange<Int64> { for dx in -1...1 as ClosedRange<Int64> { added = cells.insert(k + dy * 1_000_000 + dx).inserted || added } }
        return added
    }

    /// Revealed cells inside a map view's bounds, at most `limit` of them.
    func cells(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, limit: Int = 4000) -> [Int64] {
        var out: [Int64] = []
        for k in cells {
            let c = Self.center(k)
            if c.latitude >= sw.latitude, c.latitude <= ne.latitude, c.longitude >= sw.longitude, c.longitude <= ne.longitude {
                out.append(k)
                if out.count == limit { break }
            }
        }
        return out
    }

    /// Square kilometres revealed.
    var area: Double {
        let side = Self.cell * 111.32
        return cells.reduce(0) { $0 + side * side * cos(Self.center($1).latitude * .pi / 180) }
    }

    mutating func erase() { cells = [] }
}

/// A notable place near you (park, historic site, scenic spot, trail) that you collect by going there.
struct Discovery: Codable, Identifiable, Equatable {
    var id: String { "\(name)@\((lat * 1000).rounded()),\((lon * 1000).rounded())" } // same place found twice counts once
    var name: String
    var lat: Double
    var lon: Double
    var kind: Waypoint.Kind
    var found: Date?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    /// Apple Maps place categories that count as discoveries, and the pin each becomes.
    static var categories: [MKPointOfInterestCategory: Waypoint.Kind] {
        var map: [MKPointOfInterestCategory: Waypoint.Kind] = [
            .park: .park, .nationalPark: .park, .beach: .viewpoint, .marina: .viewpoint, .museum: .historic,
        ]
        if #available(iOS 18.0, *) {
            for c in [MKPointOfInterestCategory.landmark, .castle, .fortress, .nationalMonument] { map[c] = .historic }
            map[.hiking] = .trail
        }
        return map
    }
}

/// What the Journal adds up, and what achievements are judged on.
struct Stats {
    var distance: CLLocationDistance = 0
    var trips = 0
    var found: [Waypoint.Kind: Int] = [:]
    var area: Double = 0
    var waypoints = 0
    var hasHome = false
    var famousRoads: Set<String> = []

    var discoveries: Int { found.values.reduce(0, +) }
}

struct Achievement: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let earned: (Stats) -> Bool

    private static let mile = 1609.34

    static let all: [Achievement] = [
        .init(id: "first-ride", title: "Greenhorn", detail: "Log your first ride", symbol: "figure.equestrian.sports") { $0.trips >= 1 },
        .init(id: "rides-25", title: "Regular Rider", detail: "Log 25 rides", symbol: "calendar") { $0.trips >= 25 },
        .init(id: "100-mi", title: "Saddle Sore", detail: "Ride 100 miles", symbol: "road.lanes") { $0.distance >= 100 * mile },
        .init(id: "1000-mi", title: "Long Rider", detail: "Ride 1,000 miles", symbol: "sun.horizon.fill") { $0.distance >= 1000 * mile },
        .init(id: "parks-10", title: "Park Ranger", detail: "Discover 10 parks", symbol: "tree.fill") { $0.found[.park, default: 0] >= 10 },
        .init(id: "history-5", title: "Historian", detail: "Discover 5 historic sites", symbol: "building.columns.fill") { $0.found[.historic, default: 0] >= 5 },
        .init(id: "views-5", title: "Lookout", detail: "Discover 5 scenic spots", symbol: "binoculars.fill") { $0.found[.viewpoint, default: 0] >= 5 },
        .init(id: "trails-3", title: "Pathfinder", detail: "Discover 3 trails", symbol: "figure.hiking") { $0.found[.trail, default: 0] >= 3 },
        .init(id: "found-25", title: "Prospector", detail: "Make 25 discoveries", symbol: "sparkles") { $0.discoveries >= 25 },
        .init(id: "area-10", title: "Cartographer", detail: "Clear the fog from 10 km²", symbol: "map.fill") { $0.area >= 10 },
        .init(id: "area-100", title: "Surveyor", detail: "Clear the fog from 100 km²", symbol: "globe.americas.fill") { $0.area >= 100 },
        .init(id: "home", title: "Homesteader", detail: "Mark your home on the map", symbol: "house.fill") { $0.hasHome },
        .init(id: "pins-10", title: "Map Maker", detail: "Drop 10 waypoints", symbol: "mappin.and.ellipse") { $0.waypoints >= 10 },
        .init(id: "famous-road", title: "Legend of the Road", detail: "Drive a famous highway", symbol: "star.fill") { !$0.famousRoads.isEmpty },
    ]

    /// Road names worth an achievement, matched against Apple's turn instructions.
    static let famousRoads = [
        "route 66", "pacific coast highway", "blue ridge parkway", "going-to-the-sun", "overseas highway", "great ocean road",
        "trans-canada", "karakoram", "atlantic ocean road", "stelvio", "transfăgărășan", "transfagarasan", "amalfi",
        "chapman's peak", "ring road", "marine drive", "mumbai pune expressway", "mumbai-pune expressway", "yamuna expressway",
        "east coast road", "manali", "zoji la", "khardung la",
    ]

    static func famousRoad(in text: String) -> String? {
        let t = text.lowercased()
        return famousRoads.first { t.contains($0) }
    }
}
