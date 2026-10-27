import Foundation
import CoreLocation

/// Posted speed limits from OpenStreetMap, via the public Overpass API (free, no key).
enum SpeedLimit {
    /// km/h from an OSM `maxspeed` tag: "50" → 50, "30 mph" → 48.3; "none", "walk", "IN:urban" → nil.
    static func kmh(_ tag: String) -> Double? {
        let t = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard let n = Double(t.prefix { $0.isNumber || $0 == "." }), n > 0 else { return nil }
        return t.hasSuffix("mph") ? n * 1.609344 : n
    }

    /// The limit on the road under you. shortcut: takes the first tagged road within 20 m, so at a junction
    /// it can read the cross street; match the road name from the current turn if that shows up in use.
    static func fetch(at c: CLLocationCoordinate2D) async throws -> Double? {
        struct Response: Decodable { struct Way: Decodable { let tags: [String: String]? }; let elements: [Way] }
        let query = "[out:json][timeout:10];way(around:20,\(c.latitude),\(c.longitude))[highway][maxspeed];out tags 3;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.setValue("FrontierMap/1.0 (personal iOS app)", forHTTPHeaderField: "User-Agent")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).elements.lazy.compactMap { $0.tags?["maxspeed"].flatMap(kmh) }.first
    }
}

/// Ground height along a route, from Open-Meteo's elevation API (free, no key, non-commercial use).
enum Elevation {
    static func profile(_ path: [CLLocationCoordinate2D]) async throws -> [Double] {
        let points = path.sampled(100) // the API takes up to 100 points per call
        guard !points.isEmpty else { return [] }
        var url = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        url.queryItems = [
            .init(name: "latitude", value: points.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: points.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")),
        ]
        let (data, response) = try await URLSession.shared.data(from: url.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Response: Decodable { let elevation: [Double] }
        return try JSONDecoder().decode(Response.self, from: data).elevation
    }

    /// Total metres climbed and descended.
    static func climb(_ e: [Double]) -> (up: Double, down: Double) {
        zip(e, e.dropFirst()).reduce((0, 0)) { sum, pair in
            let d = pair.1 - pair.0
            return d > 0 ? (sum.0 + d, sum.1) : (sum.0, sum.1 - d)
        }
    }
}

/// An Apple Maps link anyone can open, for sharing a place or an ETA.
func mapsLink(_ name: String, _ c: CLLocationCoordinate2D) -> URL {
    var url = URLComponents(string: "https://maps.apple.com/")!
    url.queryItems = [.init(name: "ll", value: String(format: "%.6f,%.6f", c.latitude, c.longitude)), .init(name: "q", value: name)]
    return url.url!
}
