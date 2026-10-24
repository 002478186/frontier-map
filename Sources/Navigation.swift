import MapKit

struct Destination {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

/// Follows progress through a route's turn points and says when the guide should speak.
/// shortcut: no re-routing if you leave the route; tap Directions again. Upgrade if it's missed in real use.
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
