import MapKit

struct Destination {
    let name: String
    let coordinate: CLLocationCoordinate2D
    var stay: TimeInterval = 0 // planned time at a stop; 0 for a scenic via you just pass
}

enum Travel: String, CaseIterable, Identifiable {
    case car, walk, bike
    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var onFoot: Bool { self != .car }
    /// shortcut: MapKit has no cycling routes before the iOS 26 SDK, so bikes follow walking routes timed at 16 km/h.
    /// Switch bikes to `.cycling` once CI builds with Xcode 26.
    var transport: MKDirectionsTransportType { self == .car ? .automobile : .walking }
}

/// One or more Apple Maps legs (a trip with stops), flattened into a single list of steps.
struct Route {
    struct Step {
        var instructions: String
        var distance: CLLocationDistance
        var coordinates: [CLLocationCoordinate2D]
    }

    var name = ""
    var steps: [Step]
    var coordinates: [CLLocationCoordinate2D]
    var distance: CLLocationDistance
    var expectedTravelTime: TimeInterval        // moving time
    var legTimes: [TimeInterval] = []           // moving time of each leg
    var stops: [Destination] = []
    var arrivals: [Int: Destination] = [:]      // step index → the stop reached there, final destination excluded
    var beeline = false                         // straight line, no road data (offline or off-road)

    /// Moving time plus time spent at stops.
    var totalTime: TimeInterval { expectedTravelTime + stops.dropLast().reduce(0) { $0 + $1.stay } }

    init(legs: [MKRoute], travel: Travel, stops: [Destination]) {
        self.stops = stops
        steps = []
        for (i, (leg, stop)) in zip(legs, stops).enumerated() {
            steps += leg.steps.map { Step(instructions: $0.instructions, distance: $0.distance, coordinates: $0.polyline.coordinates) }
            if i < legs.count - 1 { arrivals[steps.count - 1] = stop }
        }
        coordinates = legs.flatMap { $0.polyline.coordinates }
        distance = legs.reduce(0) { $0 + $1.distance }
        legTimes = legs.map { travel == .bike ? $0.distance / Self.bikeSpeed : $0.expectedTravelTime }
        expectedTravelTime = legTimes.reduce(0, +)
        name = legs.count == 1 ? legs[0].name : ""
    }

    static let bikeSpeed = 4.5 // m/s

    /// Straight line to the destination, for when there's no road route: off-grid, or no connection.
    static func beeline(from start: CLLocationCoordinate2D, to dest: Destination, travel: Travel) -> Route {
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: dest.coordinate.latitude, longitude: dest.coordinate.longitude))
        let speed: Double = [Travel.car: 13, .walk: 1.3, .bike: bikeSpeed][travel]!
        var r = Route(steps: [Step(instructions: "", distance: 0, coordinates: [start]),
                              Step(instructions: "Arrive at \(dest.name)", distance: meters, coordinates: [dest.coordinate])],
                      coordinates: [start, dest.coordinate], distance: meters, expectedTravelTime: meters / speed)
        r.stops = [dest]
        r.legTimes = [r.expectedTravelTime]
        r.beeline = true
        r.name = "Straight line"
        return r
    }

    private init(steps: [Step], coordinates: [CLLocationCoordinate2D], distance: CLLocationDistance, expectedTravelTime: TimeInterval) {
        (self.steps, self.coordinates, self.distance, self.expectedTravelTime) = (steps, coordinates, distance, expectedTravelTime)
    }
}

/// Follows progress through a route's turn points and says when the guide should speak.
struct StepTracker {
    enum Event: Equatable {
        case approaching(Int)
        case reached(Int, announced: Bool)
    }

    let points: [CLLocation]
    var announceWithin: CLLocationDistance = 300
    var reachWithin: CLLocationDistance = 40
    private(set) var next = 1 // step 0 is where you start
    private var announced = 0

    init(points: [CLLocation], walking: Bool) {
        self.points = points
        if walking { announceWithin = 50; reachWithin = 20 }
    }

    mutating func update(_ here: CLLocation) -> Event? {
        guard next < points.count else { return nil }
        let distance = here.distance(from: points[next])
        if distance <= reachWithin {
            next += 1
            return .reached(next - 1, announced: announced == next - 1)
        }
        if distance <= announceWithin, announced != next {
            announced = next
            return .approaching(next)
        }
        return nil
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

extension Array where Element == CLLocationCoordinate2D {
    /// `n` points spaced evenly along the path by distance, both ends included.
    func sampled(_ n: Int) -> [CLLocationCoordinate2D] {
        guard count > 1, n > 1 else { return Array(prefix(Swift.max(n, 0))) }
        let loc = { (c: CLLocationCoordinate2D) in CLLocation(latitude: c.latitude, longitude: c.longitude) }
        var along = [0.0]
        for i in 1..<count { along.append(along[i - 1] + loc(self[i - 1]).distance(from: loc(self[i]))) }
        guard let total = along.last, total > 0 else { return Array(repeating: self[0], count: n) }
        var out: [CLLocationCoordinate2D] = [], j = 1
        for k in 0..<n {
            let target = total * Double(k) / Double(n - 1)
            while j < count - 1 && along[j] < target { j += 1 }
            let span = along[j] - along[j - 1], t = span > 0 ? (target - along[j - 1]) / span : 0
            let a = self[j - 1], b = self[j]
            out.append(.init(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t))
        }
        return out
    }
}
