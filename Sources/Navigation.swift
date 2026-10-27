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

/// Where you are along a route and when the guide should speak. Progress is measured along the road (your fix
/// projected onto the route line), so a turn counts as passed even if GPS never puts you right on its corner.
struct StepTracker {
    enum Event: Equatable {
        case prepare(Int)  // a few hundred metres out: "In 300 m, turn right…"
        case now(Int)      // right before the turn: "Turn right…"
        case reached(Int)  // driven past it
    }

    let path: [CLLocationCoordinate2D]
    let along: [CLLocationDistance]  // distance from the start to each point of `path`
    let turns: [CLLocationDistance]  // distance from the start to where each step begins
    let walking: Bool
    private(set) var next = 1        // step 0 is where you start
    private(set) var progress: CLLocationDistance = 0
    private(set) var offBy: CLLocationDistance = 0    // metres from the route line
    private(set) var remaining: [CLLocationCoordinate2D]
    private var segment = 0
    private var prepared = 0, called = 0

    /// `steps`: each step's line; a step begins at its first point (Apple's step 0 is where you start).
    init(steps: [[CLLocationCoordinate2D]], walking: Bool) {
        var path: [CLLocationCoordinate2D] = [], along: [CLLocationDistance] = [], turns: [CLLocationDistance] = []
        for step in steps {
            for (j, c) in step.enumerated() {
                if let last = path.last {
                    let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                        .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                    if d >= 0.5 { // steps share their end points; don't repeat them
                        path.append(c)
                        along.append(along[along.count - 1] + d)
                    }
                } else {
                    path.append(c)
                    along.append(0)
                }
                if j == 0 { turns.append(along[along.count - 1]) }
            }
            if step.isEmpty { turns.append(along.last ?? 0) }
        }
        (self.path, self.along, self.turns, self.walking, remaining) = (path, along, turns, walking, path)
    }

    /// Distance along the road to the next turn.
    var toNext: CLLocationDistance? { next < turns.count ? turns[next] - progress : nil }

    mutating func update(_ here: CLLocation, speed: CLLocationSpeed = 0) -> [Event] {
        guard path.count > 1 else { return [] }
        locate(here.coordinate)
        var events: [Event] = []
        while next < turns.count, progress >= turns[next] - (walking ? 5 : 10) {
            events.append(.reached(next))
            next += 1
        }
        guard let ahead = toNext else { return events }
        // "Now" about 30 m out (20 m on foot), earlier at speed so there's time to hear it.
        let now = walking ? 20 : max(30, speed * 2.5)
        let early = walking ? 60.0 : speed > 20 ? 800 : 300
        if ahead <= now, called != next {
            called = next
            prepared = next
            events.append(.now(next))
        } else if ahead <= early, ahead > now * 2, prepared != next {
            prepared = next
            events.append(.prepare(next))
        }
        return events
    }

    /// Projects a fix onto the route, looking a little behind and up to 2 km ahead of the last spot, or along the
    /// whole route if that's far off (a GPS jump, or starting somewhere else).
    private mutating func locate(_ p: CLLocationCoordinate2D) {
        var to = segment
        while to < path.count - 2, along[to] < progress + 2000 { to += 1 }
        var best = nearest(p, in: max(segment - 2, 0)...to)
        if best.distance > 100 { best = nearest(p, in: 0...(path.count - 2)) }
        segment = best.segment
        offBy = best.distance
        progress = along[segment] + best.t * (along[segment + 1] - along[segment])
        let a = path[segment], b = path[segment + 1]
        let at = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * best.t,
                                        longitude: a.longitude + (b.longitude - a.longitude) * best.t)
        remaining = [at] + path[(segment + 1)...]
    }

    private func nearest(_ p: CLLocationCoordinate2D, in range: ClosedRange<Int>) -> (segment: Int, t: Double, distance: Double) {
        let k = 111_320.0, kx = k * cos(p.latitude * .pi / 180)
        var best = (segment: range.lowerBound, t: 0.0, distance: Double.infinity)
        for i in range {
            let ax = (path[i].longitude - p.longitude) * kx, ay = (path[i].latitude - p.latitude) * k
            let bx = (path[i + 1].longitude - p.longitude) * kx, by = (path[i + 1].latitude - p.latitude) * k
            let dx = bx - ax, dy = by - ay, len = dx * dx + dy * dy
            let t = len == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / len))
            let d = hypot(ax + t * dx, ay + t * dy)
            if d < best.distance { best = (i, t, d) }
        }
        return best
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
