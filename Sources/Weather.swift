import Foundation
import CoreLocation

/// Current weather and the next sunrise/sunset from Open-Meteo (free, no key, non-commercial use), in frontier words.
struct Weather: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double   // °C
        let weather_code: Int        // WMO code
        let wind_speed_10m: Double   // km/h
        let wind_direction_10m: Double // where the wind blows from, degrees
    }
    struct Daily: Decodable { let sunrise: [TimeInterval]; let sunset: [TimeInterval] } // unix seconds
    let current: Current
    let daily: Daily

    static func fetch(at c: CLLocationCoordinate2D) async throws -> Weather {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: "\(c.latitude)"), .init(name: "longitude", value: "\(c.longitude)"),
            .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m"),
            .init(name: "daily", value: "sunrise,sunset"), .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"), .init(name: "forecast_days", value: "2"),
        ]
        let (data, response) = try await URLSession.shared.data(from: url.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Weather.self, from: data)
    }

    var sky: String {
        switch current.weather_code {
        case 0: "Clear skies"
        case 1, 2: "Few clouds driftin' by"
        case 3: "Sky's gone grey"
        case 45, 48: "Fog's rolled in"
        case 51...57: "Light drizzle"
        case 61...67, 80...82: "Rain comin' down"
        case 71...77, 85, 86: "Snow fallin'"
        case 95...99: "Storm rollin' in"
        default: "Strange weather"
        }
    }

    /// e.g. "Sun sets 6:41 PM", or the next sunrise once the sun's down.
    func daylight(now: Date = .now) -> String {
        let t = now.timeIntervalSince1970
        let time = { (s: TimeInterval) in Date(timeIntervalSince1970: s).formatted(date: .omitted, time: .shortened) }
        if let rise = daily.sunrise.first, t < rise { return "Sunrise \(time(rise))" }
        if let set = daily.sunset.first, t < set { return "Sun sets \(time(set))" }
        return daily.sunrise.dropFirst().first.map { "Sunrise \(time($0))" } ?? ""
    }

    /// "64°" on screen, "64 degrees Fahrenheit" spoken; units follow the phone's region.
    func temperature(spoken: Bool = false) -> String {
        Measurement(value: current.temperature_2m, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: spoken ? .wide : .narrow, usage: .weather))
    }

    /// Short line for the on-screen chip.
    func chip(now: Date = .now) -> String { "\(temperature()) · \(sky) · \(daylight(now: now))" }

    /// What the guide says when the chip is tapped.
    func spoken(now: Date = .now) -> String {
        let wind = current.wind_speed_10m >= 25
            ? " Strong wind from the \(Geo.compassPoint(current.wind_direction_10m))." : ""
        return "\(sky). \(temperature(spoken: true)).\(wind) \(daylight(now: now))."
    }
}
