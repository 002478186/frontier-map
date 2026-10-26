import SwiftUI
import CoreLocation

struct Waypoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var kind = Kind.pin

    /// Pin categories in the style of a frontier map legend: colour by group, white glyph.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case pin, camp, home, horse, treasure, hunting, fishing, campfire, shop, saloon, doctor, lodging, mountain, mystery
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .pin: "mappin"
            case .camp: "tent.fill"
            case .home: "house.fill"
            case .horse: "figure.equestrian.sports"
            case .treasure: "xmark"
            case .hunting: "pawprint.fill"
            case .fishing: "fish.fill"
            case .campfire: "flame.fill"
            case .shop: "cart.fill"
            case .saloon: "wineglass.fill"
            case .doctor: "cross.case.fill"
            case .lodging: "bed.double.fill"
            case .mountain: "mountain.2.fill"
            case .mystery: "questionmark"
            }
        }

        var color: Color {
            switch self {
            case .camp, .home, .fishing: Color(red: 0.33, green: 0.65, blue: 0.71)   // wilds: teal
            case .horse: Color(red: 0.27, green: 0.30, blue: 0.47)                    // riding: navy
            case .treasure, .hunting, .campfire: Color(red: 0.86, green: 0.39, blue: 0.18) // finds: orange
            case .shop, .saloon, .doctor, .lodging: Color(red: 0.31, green: 0.38, blue: 0.24) // town: green
            case .pin, .mountain: Color(red: 0.80, green: 0.69, blue: 0.50)           // landmarks: tan
            case .mystery: Color(red: 0.60, green: 0.33, blue: 0.24)                  // unknown: brown
            }
        }

        var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init(id: UUID = UUID(), name: String, lat: Double, lon: Double, kind: Kind = .pin) {
        (self.id, self.name, self.lat, self.lon, self.kind) = (id, name, lat, lon, kind)
    }

    /// Pins saved before categories existed have no "kind"; keep them as plain pins instead of dropping them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .pin
    }

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
