import Foundation
import CoreLocation

struct Waypoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    static func load() -> [Waypoint] {
        UserDefaults.standard.data(forKey: "waypoints")
            .flatMap { try? JSONDecoder().decode([Waypoint].self, from: $0) } ?? []
    }

    static func save(_ waypoints: [Waypoint]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(waypoints), forKey: "waypoints")
    }
}

enum Geo {
    /// Initial great-circle bearing in degrees: 0 = north, clockwise.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    static func compassPoint(_ degrees: Double) -> String {
        let names = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
        return names[Int((degrees + 22.5) / 45) % 8]
    }
}
