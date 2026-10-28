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

/// Open or closed right now, from OpenStreetMap's `opening_hours` tag via Overpass (Apple Maps doesn't share hours).
enum OpeningHours {
    static let week = 7 * 1440
    private static let days = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

    /// Open minutes of the week (Monday 00:00 = 0) from a tag like "Mo-Fr 09:00-18:00; Sa 10:00-14:00; Su off".
    /// shortcut: plain day/time rules and 24/7 only; months, holidays and "sunset" give nil (unknown), add them if
    /// places nearby show no hours.
    static func parse(_ tag: String) -> [Range<Int>]? {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        if tag == "24/7" { return [0..<week] }
        var byDay = [[Range<Int>]](repeating: [], count: 7)
        // ", Sa 10:00" starts a new rule just like "; Sa 10:00".
        let rules = tag.replacingOccurrences(of: #",\s+(?=[A-Z][a-z][ ,-])"#, with: ";", options: .regularExpression)
        for rule in rules.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !rule.isEmpty {
            if rule.hasPrefix("PH") || rule.hasPrefix("SH") { continue } // holidays: ignored
            var parts = rule.split(separator: " ", maxSplits: 1).map(String.init)
            var which = Array(0..<7)
            if let first = parts.first, first.first?.isLetter == true, first.lowercased() != "off", first.lowercased() != "closed" {
                guard let d = daySet(first) else { return nil }
                which = d
                parts.removeFirst()
            }
            let times = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            var spans: [Range<Int>] = []
            if !["off", "closed"].contains(times.lowercased()) {
                for span in times.split(separator: ",") {
                    let ends = span.split(separator: "-").compactMap { minutes(String($0)) }
                    guard ends.count == 2 else { return nil }
                    spans.append(ends[0]..<(ends[1] > ends[0] ? ends[1] : ends[1] + 1440)) // past midnight
                }
            }
            for d in which { byDay[d] = spans } // a later rule replaces earlier ones for its days
        }
        return byDay.enumerated().flatMap { d, spans in spans.map { (d * 1440 + $0.lowerBound)..<(d * 1440 + $0.upperBound) } }
    }

    /// "Mo-Fr,Su" → [0, 1, 2, 3, 4, 6].
    private static func daySet(_ s: String) -> [Int]? {
        var out: [Int] = []
        for piece in s.split(separator: ",") {
            let ends = piece.split(separator: "-").map { days.firstIndex(of: String($0)) }
            guard let a = ends.first ?? nil, let b = ends.last ?? nil, ends.count <= 2 else { return nil }
            out += a <= b ? Array(a...b) : Array(a..<7) + Array(0...b)
        }
        return out
    }

    private static func minutes(_ s: String) -> Int? {
        let hm = s.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        return hm.count == 2 && hm[0] <= 24 && hm[1] < 60 ? hm[0] * 60 + hm[1] : nil
    }

    /// Open now, and when that changes (nil: never, e.g. 24/7 or always closed).
    static func status(_ open: [Range<Int>], at date: Date, calendar: Calendar) -> (open: Bool, change: Date?) {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let now = ((c.weekday! + 5) % 7) * 1440 + c.hour! * 60 + c.minute! // weekday 2 is Monday
        let at = { (m: Int) in calendar.date(byAdding: .minute, value: m - now, to: date).map { calendar.dateInterval(of: .minute, for: $0)!.start } }
        // Copies a week either side, so spans past Sunday midnight wrap to Monday.
        let all = open.flatMap { [$0, ($0.lowerBound - week)..<($0.upperBound - week), ($0.lowerBound + week)..<($0.upperBound + week)] }
        if var end = all.first(where: { $0.contains(now) })?.upperBound {
            while end - now < week, let more = all.first(where: { $0.contains(end) }) { end = more.upperBound } // back-to-back days
            return (true, end - now >= week ? nil : at(end))
        }
        return (false, all.map(\.lowerBound).filter { $0 > now }.min().flatMap(at))
    }

    /// The tag on the OSM place with this name within 80 m.
    static func fetch(name: String, at c: CLLocationCoordinate2D) async throws -> String? {
        struct Response: Decodable { struct Element: Decodable { let tags: [String: String]? }; let elements: [Element] }
        let query = "[out:json][timeout:10];nwr(around:80,\(c.latitude),\(c.longitude))[name][opening_hours];out tags 20;"
        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.setValue("FrontierMap/1.0 (personal iOS app)", forHTTPHeaderField: "User-Agent")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let key = name.lowercased()
        return try JSONDecoder().decode(Response.self, from: data).elements.lazy.compactMap { e -> String? in
            guard let n = e.tags?["name"]?.lowercased(), n.contains(key) || key.contains(n) else { return nil }
            return e.tags?["opening_hours"]
        }.first
    }
}
